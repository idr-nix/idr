top: {
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.idr.mesh;
  port = types.ints.between 1 65535;
  ipv6Prefix = types.strMatching "fd[0-9a-f]{2}(:[0-9a-f]{4}){2}";
  meshPackage = pkgs.callPackage ./. {};
  meshExe = lib.getExe meshPackage;
  # A package-only switch must not tear down resources held by active oneshots.
  setupTarget = "idr-mesh/bin/idr-mesh";
  setupExe = "/etc/${setupTarget}";
  # systemd expands % specifiers in LoadCredential= values.
  literal = lib.replaceStrings ["%"] ["%%"];
  loadCredential = name: secret: "${name}:${literal (toString secret.path)}";
  etcdPassword = config.idr.secrets.idr-mesh-etcd-password;
  meshEtcd = {
    credentials = [(loadCredential "password" etcdPassword)];
    restartTargets = [etcdPassword.restartTarget];
    command = name: flags:
      utils.escapeSystemdExecArgs ([meshExe name] ++ flags)
      + " -- "
      + utils.escapeSystemdExecArgs [cfg.etcd.endpoint cfg.etcd.username]
      + " %d/password";
  };
  # Modular services can own subservices. Use their systemd unit names as
  # inventory keys, including when a subservice has the empty name.
  collect = name: service:
    lib.optionalAttrs ((service.idr or {}) ? mesh) {
      ${name} = {inherit (service.idr.mesh) id peers;};
    }
    // lib.concatMapAttrs (child: collect (lib.concatStringsSep "-" (lib.filter (part: part != "") [name child]))) service.services;
  # Each PSK becomes a local secret: a source, or an alias of a reference.
  pskName = name: peer: "idr-mesh-psk-${top.idr-lib.shortHash 16 name}-${peer}";
  meshServices = lib.mapAttrs (name: service: let
    psks = lib.mapAttrs (peer: _: config.idr.secrets.${pskName name peer}) service.peers;
  in
    service
    // {
      settingsFile = pkgs.writeText "idr-mesh-settings.json" (builtins.toJSON {
        inherit (service) id;
        peers = lib.mapAttrs (_: psk: {psk = toString psk.path;}) psks;
      });
      pskTargets = lib.unique (lib.mapAttrsToList (_: psk: psk.restartTarget) psks);
    }) (lib.concatMapAttrs collect config.system.services);
in {
  key = toString ./nixos-module.nix;

  imports = with lib.modules; [
    (importApply ./health.nix {inherit meshExe;})
    (importApply ./netd.nix {inherit meshExe;})
    (importApply ./netns.nix {inherit setupExe meshServices;})
    (importApply ./dns.nix {inherit setupExe meshServices;})
    (importApply ./agent.nix {inherit meshExe meshEtcd;})
    (importApply ./psk.nix {inherit meshExe meshServices;})
    (importApply ./metrics.nix {inherit meshExe;})
  ];

  options.idr.mesh = {
    enable = lib.mkEnableOption "the service WireGuard mesh";

    ipv6Prefix = mkOption {
      type = ipv6Prefix;
      default = "fdb4:cb46:0ef1";
      description = "Mesh IPv6 /48 prefix as three full lowercase hexadecimal groups. Use the same value on all participating machines.";
    };

    dns.ipv6Prefix = mkOption {
      type = ipv6Prefix;
      default = "fd63:51c5:a6f0";
      description = "Local IPv6 /48 prefix for isolated mesh DNS links, as three full lowercase hexadecimal groups.";
    };

    publicAddresses = mkOption {
      type = types.listOf types.nonEmptyStr;
      default = [];
      example = ["2001:db8::10" "203.0.113.10"];
      description = "Advertise the first 129 distinct WireGuard endpoint addresses in the supplied order. An empty list discovers publicly routable addresses on active interfaces, with IPv6 first.";
    };

    portRange = {
      from = mkOption {
        type = port;
        default = 30000;
        description = "First port of the mesh UDP range, reserved for health checks. WireGuard instances use the remaining ports.";
      };
      to = mkOption {
        type = port;
        default = 32767;
        description = "Last UDP port available for local mesh instances, inclusive.";
      };
    };

    etcd = {
      leaseTTLSeconds = mkOption {
        type = types.ints.between 1 9000000000;
        default = 60;
        description = "Requested lifetime of the etcd lease for a mesh instance. The agent renews it using the TTL returned by the server.";
      };
      endpoint = mkOption {
        type = types.nonEmptyStr;
        example = "http://main.etcd.internal:1023";
        description = "etcd client endpoint URL, reachable independently of the service mesh. Configure upstream servers and TLS trust on the local etcd proxy. An HTTPS endpoint is verified against the system trust store, which `security.pki.certificateFiles` extends.";
      };
      username = mkOption {
        type = types.nonEmptyStr;
        description = "etcd user for this machine's mesh agent.";
      };
      password = mkOption {
        type = top.idr-lib.types.secretOrSource;
        example = lib.literalExpression ''{ sopsFile = ./mesh-etcd.enc.json; key = "password"; }'';
        description = "The etcd user's password, as a runtime secret reference or a secret source. The RBAC machines also read a source and become recipients of its SOPS file, so keep it in a file of its own; list RBAC machines of other projects in its recipientMachines. A reference stays local: also set the user's password on the RBAC machines.";
      };
      access = mkOption {
        type = types.raw;
        internal = true;
        readOnly = true;
        description = "The etcd access this machine's agent needs, from which `idr-lib.meshRbac` derives its role. Disabled services keep their access.";
        default = let
          write = lib.unique (lib.mapAttrsToList (_: service: service.id) meshServices);
          peers = lib.concatMap (service: lib.attrNames service.peers) (lib.attrValues meshServices);
        in {
          inherit (cfg) ipv6Prefix;
          user = cfg.etcd.username;
          # Other machines can read a source, but not a local reference.
          password =
            if top.idr-lib.isSecret cfg.etcd.password
            then null
            else cfg.etcd.password;
          inherit write;
          read = lib.subtractLists write (lib.unique peers);
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc.${setupTarget}.source = meshExe;
    # `idr-mesh status` for operators.
    environment.systemPackages = [meshPackage];
    idr.secrets-source =
      {idr-mesh-etcd-password = cfg.etcd.password;}
      // lib.concatMapAttrs (name: service:
        lib.mapAttrs' (peer: declaration: lib.nameValuePair (pskName name peer) declaration.psk) service.peers)
      meshServices;
    # The agent and netd read the enabled services from one generation.
    environment.etc."idr-mesh/services.json".text = builtins.toJSON {
      inherit (cfg) ipv6Prefix;
      services = lib.mapAttrs (_: service: {
        inherit (service) id;
        peers = lib.attrNames service.peers;
      }) (lib.filterAttrs (name: _: config.systemd.services.${name}.enable) meshServices);
    };
    assertions = [
      {
        assertion = cfg.dns.ipv6Prefix != cfg.ipv6Prefix;
        message = "idr.mesh.dns.ipv6Prefix must differ from the mesh IPv6 prefix.";
      }
      {
        assertion = cfg.portRange.from < cfg.portRange.to;
        message = "idr.mesh.portRange must contain at least two ports: one for health checks and at least one for WireGuard instances.";
      }
      {
        assertion = builtins.match "https?://[^[:space:]]+" cfg.etcd.endpoint != null;
        message = "idr.mesh.etcd.endpoint must be an HTTP or HTTPS URL.";
      }
    ];
  };
}

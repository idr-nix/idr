top: {
  config,
  lib,
  pkgs,
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
  # Each cluster's password becomes a local secret. The agent reads it at each
  # login, so a new password needs no restart.
  passwordName = cluster: "idr-mesh-etcd-password-${cluster}";
  passwords = lib.mapAttrs (cluster: _: config.idr.secrets.${passwordName cluster}) cfg.etcd;
  meshEtcd = {
    groups = lib.unique (lib.mapAttrsToList (_: password: password.group) passwords);
    # Only to start after the passwords exist.
    targets = lib.unique (lib.mapAttrsToList (_: password: password.restartTarget) passwords);
    clusters = pkgs.writeText "idr-mesh-etcd.json" (builtins.toJSON (lib.mapAttrsToList (cluster: settings: {
        inherit (settings) ipv6Prefix leaseTTLSeconds endpoint username;
        passwordFile = toString passwords.${cluster}.path;
      })
      cfg.etcd));
  };
  # Modular services can own subservices. Use their systemd unit names as
  # inventory keys, including when a subservice has the empty name.
  collect = name: service:
    lib.optionalAttrs ((service.idr or {}) ? mesh) {
      ${name} = {inherit (service.idr.mesh) id etcd peers publish internet;};
    }
    // lib.concatMapAttrs (child: collect (lib.concatStringsSep "-" (lib.filter (part: part != "") [name child]))) service.services;
  # Each PSK becomes a local secret: a source, or an alias of a reference.
  pskName = name: peer: "idr-mesh-psk-${top.idr-lib.shortHash 16 name}-${peer}";
  prefixOf = cluster:
    if cluster != null && cfg.etcd ? ${cluster}
    then cfg.etcd.${cluster}.ipv6Prefix
    else null;
  declaredServices = lib.concatMapAttrs collect config.system.services;
  clusterOf = service:
    if service.etcd != null
    then service.etcd
    else cfg.defaultEtcd;
  # The service of this machine with an ID in a cluster, if it is the only one.
  localService = id: cluster: let
    found = lib.attrNames (lib.filterAttrs (_: service: service.id == id && clusterOf service == cluster) declaredServices);
  in
    if lib.length found == 1
    then lib.head found
    else null;
  # Peers in the service's own cluster are reached over WireGuard, `peers`
  # here, and those in other clusters over links on this machine, `links`.
  meshServices = lib.mapAttrs (name: declared: let
    cluster = clusterOf declared;
    peerCluster = peer:
      if peer.etcd != null
      then peer.etcd
      else cluster;
    peers = lib.filterAttrs (_: peer: peerCluster peer == cluster) declared.peers;
    links = lib.mapAttrs (id: peer: {
      cluster = peerCluster peer;
      workload = localService id (peerCluster peer);
      inherit (peer) names routes;
      # Of the routes, this service forwards its own peers for the linked
      # workload, and reaches the others through it.
      forwards = lib.filter (route: peers ? ${route}) peer.routes;
      reaches = lib.filter (route: !(peers ? ${route})) peer.routes;
    }) (lib.filterAttrs (_: peer: peerCluster peer != cluster) declared.peers);
    psks = lib.mapAttrs (peer: _: config.idr.secrets.${pskName name peer}) (lib.filterAttrs (_: peer: peer.psk != null) peers);
  in
    declared
    // {
      inherit cluster peers links;
      ipv6Prefix = prefixOf cluster;
      settingsFile = pkgs.writeText "idr-mesh-settings.json" (builtins.toJSON {
        inherit (declared) id;
        ipv6Prefix = prefixOf cluster;
        peers =
          lib.mapAttrs (peer: psk: {
            psk = toString psk.path;
            inherit (peers.${peer}) names;
          })
          psks;
        links =
          lib.mapAttrs (_: link: {
            ipv6Prefix = prefixOf link.cluster;
            inherit (link) names workload forwards;
          })
          links;
      });
      pskTargets = lib.unique (lib.mapAttrsToList (_: psk: psk.restartTarget) psks);
    })
  declaredServices;
in {
  key = toString ./nixos-module.nix;

  imports = with lib.modules; [
    (importApply ./health.nix {inherit meshExe;})
    (importApply ./netd.nix {inherit meshExe;})
    (importApply ./netns.nix {inherit setupExe meshServices;})
    (importApply ./dns.nix {inherit setupExe meshServices;})
    (importApply ./publish.nix {inherit setupExe meshServices;})
    (importApply ./link.nix {inherit setupExe meshServices;})
    (importApply ./agent.nix {inherit meshExe meshEtcd;})
    (importApply ./psk.nix {inherit meshExe meshServices;})
    (importApply ./metrics.nix {inherit meshExe;})
  ];

  options.idr.mesh = {
    enable = lib.mkEnableOption "the service WireGuard mesh";

    dns.ipv6Prefix = mkOption {
      type = ipv6Prefix;
      default = "fd63:51c5:a6f0";
      description = "Local IPv6 /48 prefix for isolated mesh DNS links, as three full lowercase hexadecimal groups.";
    };

    internet.nameservers = mkOption {
      type = types.listOf types.nonEmptyStr;
      default = config.networking.nameservers;
      defaultText = lib.literalExpression "config.networking.nameservers";
      description = "DNS resolvers on the internet that workloads with internet access use for names outside the mesh; the first two count.";
    };

    published = {
      ipv6Prefix = mkOption {
        type = ipv6Prefix;
        default = "fd2e:9c41:57b3";
        description = "Local IPv6 /48 prefix for the links that carry published ports, as three full lowercase hexadecimal groups.";
      };
      ipv4Prefix = mkOption {
        type = types.strMatching "(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])";
        default = "10.201";
        example = "172.30";
        description = "Local IPv4 /16 prefix for the links that carry published ports, as its first two octets.";
      };
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

    defaultEtcd = mkOption {
      type = types.nullOr types.str;
      default =
        if lib.length (lib.attrNames cfg.etcd) == 1
        then lib.head (lib.attrNames cfg.etcd)
        else null;
      defaultText = lib.literalMD "the only cluster in `idr.mesh.etcd`, if there is one";
      example = "main";
      description = "The `idr.mesh.etcd` cluster that services register in unless they choose another.";
    };

    etcd = mkOption {
      type = types.attrsOf (types.submodule ({
        name,
        config,
        ...
      }: {
        options = {
          ipv6Prefix = mkOption {
            type = ipv6Prefix;
            default = "fdb4:cb46:0ef1";
            description = "IPv6 /48 prefix of the mesh in this cluster, as three full lowercase hexadecimal groups. Use the same value on all machines, and a different one for each cluster.";
          };
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
            description = "etcd user for this machine's mesh agent. Each cluster in the same etcd needs a user of its own.";
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
            description = "The etcd access this machine's agent needs in this cluster, from which `idr-lib.meshRbac` derives its role. Disabled services keep their access.";
            default = let
              services = lib.filterAttrs (_: service: service.cluster == name) meshServices;
              write = lib.unique (lib.mapAttrsToList (_: service: service.id) services);
              peers = lib.concatMap (service: lib.attrNames service.peers) (lib.attrValues services);
            in {
              inherit (config) ipv6Prefix;
              user = config.username;
              # Other machines can read a source, but not a local reference.
              password =
                if top.idr-lib.isSecret config.password
                then null
                else config.password;
              inherit write;
              read = lib.subtractLists write (lib.unique peers);
            };
          };
        };
      }));
      default = {};
      description = "etcd clusters that this machine's services register in, by names that mean the same cluster on every machine. Each cluster holds a mesh of its own.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc.${setupTarget}.source = meshExe;
    # `idr-mesh status` for operators.
    environment.systemPackages = [meshPackage];
    idr.secrets-source =
      lib.mapAttrs' (cluster: settings: lib.nameValuePair (passwordName cluster) settings.password) cfg.etcd
      // lib.concatMapAttrs (name: service:
        lib.mapAttrs' (peer: declaration: lib.nameValuePair (pskName name peer) declaration.psk)
        (lib.filterAttrs (_: peer: peer.psk != null) service.peers))
      meshServices;
    # The agent and netd read the enabled services from one generation.
    environment.etc."idr-mesh/services.json".text = builtins.toJSON {
      services = lib.mapAttrs (_: service: {
        inherit (service) id ipv6Prefix;
        peers = lib.attrNames service.peers;
        maxInstances = lib.mapAttrs (_: peer: peer.maxInstances) service.peers;
      }) (lib.filterAttrs (name: _: config.systemd.services.${name}.enable) meshServices);
    };
    assertions = let
      services = lib.attrValues meshServices;
      known = cluster: cluster != null && cfg.etcd ? ${cluster};
    in [
      {
        assertion = lib.allUnique (lib.mapAttrsToList (_: settings: settings.ipv6Prefix) cfg.etcd ++ [cfg.dns.ipv6Prefix cfg.published.ipv6Prefix]);
        message = "Each cluster in idr.mesh.etcd needs its own ipv6Prefix, which must also differ from idr.mesh.dns.ipv6Prefix and idr.mesh.published.ipv6Prefix.";
      }
      {
        assertion = cfg.portRange.from < cfg.portRange.to;
        message = "idr.mesh.portRange must contain at least two ports: one for health checks and at least one for WireGuard instances.";
      }
      {
        assertion = lib.all (cluster: builtins.match "[A-Za-z0-9_-]+" cluster != null) (lib.attrNames cfg.etcd);
        message = "Names of clusters in idr.mesh.etcd may contain only letters, digits, - and _.";
      }
      {
        assertion = lib.all (settings: builtins.match "https?://[^[:space:]]+" settings.endpoint != null) (lib.attrValues cfg.etcd);
        message = "idr.mesh.etcd.<name>.endpoint must be an HTTP or HTTPS URL.";
      }
      {
        assertion = cfg.defaultEtcd == null || known cfg.defaultEtcd;
        message = "idr.mesh.defaultEtcd must name a cluster in idr.mesh.etcd.";
      }
      {
        assertion = lib.all (service: known service.cluster && lib.all (link: known link.cluster) (lib.attrValues service.links)) services;
        message = "Each mesh service and peer needs a cluster in idr.mesh.etcd: set idr.mesh.defaultEtcd, or name a cluster in the service's idr.mesh.etcd or the peer's etcd.";
      }
      {
        assertion = lib.all (service: lib.all (peer: peer.psk != null) (lib.attrValues service.peers)) services;
        message = "Each mesh peer in its service's own cluster needs a psk.";
      }
    ];
  };
}

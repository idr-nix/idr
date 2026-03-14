top: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.disk-unlock.server;
  members = lib.filterAttrs (_: member: builtins.elem "unlock-server" (member.groups or [])) top.idr-lib.team;
  member = members.${cfg.member};
  port = member.port or 64998;
  sshPrivateKey = (builtins.head (builtins.filter (key: key.type == "ed25519") config.services.openssh.hostKeys)).path;
  targets = lib.listToAttrs (lib.concatMap (node: let
    profile = node.profiles.system or {};
    idr = profile.path.idr or {};
    meta = idr.meta or {};
    diskKey = meta.disko.preFormatFiles."/disk-key.txt" or null;
  in
    lib.optional (diskKey != null && (meta.initrdHostPublicKey or null) != null && (idr.qemuProcess or null) == null)
    (lib.nameValuePair "${meta.machine}-${meta.machineId}" {
      inherit diskKey;
      host = node.hostname;
      port = meta.initrdPort;
      hostPublicKey = meta.initrdHostPublicKey;
      sshOpts = (profile.sshOpts or []) ++ (node.sshOpts or []) ++ idr.globalSshOpts;
    }))
  cfg.nodes);
  manifest = pkgs.writers.writeJSON "idr-disk-unlock.json" {
    inherit sshPrivateKey;
    targets =
      lib.mapAttrs (name: target: {
        inherit (target) host port sshOpts;
        diskKey = config.sops.secrets."idr-disk-unlock-${name}".path;
        knownHosts = pkgs.writeText "idr-disk-unlock-${name}.known-hosts" ''
          * ${target.hostPublicKey}
        '';
      })
      targets;
  };
  unlock = pkgs.writers.writeNu "idr-disk-unlock" (builtins.readFile ./unlock.nu);
in {
  options.idr.disk-unlock.server = {
    enable = lib.mkEnableOption "automatic disk unlocking for deployed machines";
    nodes = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [];
      description = "Deploy-rs nodes whose production system profiles this server may unlock.";
    };
    member = lib.mkOption {
      type = lib.types.str;
      default = "${config.networking.hostName}-${config.idr.preset.base.id}";
      defaultText = lib.literalExpression ''"''${config.networking.hostName}-''${config.idr.preset.base.id}"'';
      description = "Team system member in the unlock-server group, providing this server's notification port.";
    };
    timeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "Maximum time in seconds to handle a notification and unlock its target.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [port];

    sops.secrets = lib.mapAttrs' (name: target:
      lib.nameValuePair "idr-disk-unlock-${name}" {
        inherit (target.diskKey) sopsFile key;
        format = "json";
        mode = "0400";
      })
    targets;

    systemd.sockets.idr-disk-unlock = {
      description = "Disk-unlock notifications";
      wantedBy = ["sockets.target"];
      listenStreams = [(toString port)];
      socketConfig.Accept = true;
    };

    systemd.services."idr-disk-unlock@" = {
      description = "Unlock a configured machine";
      wants = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
      after = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
      path = [pkgs.openssh pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        StandardInput = "socket";
        StandardOutput = "journal";
        StandardError = "journal";
        TimeoutStartSec = cfg.timeout;
        ExecStart = "${unlock} ${manifest}";
      };
    };
  };
}

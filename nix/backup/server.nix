_: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.backup.server;
  identity = (builtins.head (builtins.filter (key: key.type == "ed25519") config.services.openssh.hostKeys)).path;
  machineId = config.idr.preset.base.id or null;
  localMachine =
    if machineId == null
    then null
    else "${config.networking.hostName}-${machineId}";
  targets = lib.listToAttrs (lib.concatMap (node: let
    profile = node.profiles.system or {};
    idr = profile.path.idr or {};
    meta = idr.meta or {};
    name = "${meta.machine}-${meta.machineId}";
  in
    lib.optional ((meta.backup or null) != null && (meta.sshHostPublicKey or null) != null && (idr.qemuProcess or null) == null && name != localMachine)
    (lib.nameValuePair name {
      inherit (meta) machineId;
      inherit (meta.backup) user datasets port networkPrefix;
      alias = "idr-backup-${name}";
      host = node.hostname;
      destination = "${cfg.dataset}/${name}";
      sshOptions = (profile.sshOpts or []) ++ (node.sshOpts or []) ++ idr.globalSshOpts;
      knownHosts = pkgs.writeText "idr-backup-${name}.known-hosts" ''
        * ${meta.sshHostPublicKey}
      '';
    }))
  cfg.nodes);
  prepare = pkgs.writers.writeNu "idr-backup-prepare" ''
    let dataset = ${builtins.toJSON cfg.dataset}
    let exists = ^/run/booted-system/sw/bin/zfs list -H -o name $dataset | complete
    if $exists.exit_code != 0 {
      ^/run/booted-system/sw/bin/zfs create -p -o canmount=off -o mountpoint=none $dataset
    }
    ^/run/booted-system/sw/bin/zfs set syncoid:sync=false $dataset
  '';
  worker = pkgs.writers.writeNu "idr-backup" (builtins.readFile ./replicate.nu);
in {
  options.idr.backup.server = {
    enable = lib.mkEnableOption "pull backups for deployed IDR machines";
    nodes = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [];
      description = "Deploy-rs nodes whose production system profiles this server backs up.";
    };
    dataset = lib.mkOption {
      type = lib.types.str;
      example = "p1/backups";
      description = "Destination dataset under an imported ZFS pool. Created if absent.";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "*:0/5";
      description = "Systemd calendar interval for replication.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services =
      {
        idr-backup-prepare = {
          description = "Prepare the backup destination";
          wantedBy = ["multi-user.target" "sysinit-reactivation.target"];
          after = ["zfs.target"];
          before = ["sanoid.service"];
          partOf = ["sysinit-reactivation.target"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${prepare}";
          };
        };
      }
      // lib.mapAttrs' (name: target:
        lib.nameValuePair "idr-backup-${name}" {
          description = "Back up ${name}";
          startAt = cfg.interval;
          after = ["idr-backup-prepare.service" "network.target" "sshd.service"];
          requires = ["idr-backup-prepare.service"];
          path = [pkgs.openssh pkgs.sanoid pkgs.coreutils];
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            RuntimeDirectory = "idr-backup-${name}";
            RuntimeDirectoryMode = "0700";
            UMask = "0077";
            PrivateTmp = true;
            ImportCredential = ["idr.workspace-id"];
            ExecStart = "${worker} ${pkgs.writers.writeJSON "idr-backup-${name}.json" (target // {inherit identity;})}";
          };
        })
      targets;

    services.sanoid.datasets.${cfg.dataset} = {
      use_template = ["idr_long_term"];
      recursive = true;
      autosnap = false;
      autoprune = true;
    };
  };
}

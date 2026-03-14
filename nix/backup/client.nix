top: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.backup.client;
  user = "idr-backup";
  pools = config.disko.devices.zpool or {};
  servers = lib.filterAttrs (_: member: builtins.elem "backup-server" (member.groups or [])) top.idr-lib.team;
  access = pkgs.writers.writeNu "idr-backup-access" ''
    def main [action: string] {
      for dataset in ${builtins.toJSON cfg.datasets} {
        ^/run/booted-system/sw/bin/zfs $action -u ${user} "send,hold" $dataset
      }
    }
  '';
in {
  options.idr.backup.client = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = (config.idr.preset.base.enable or false) && !config.boot.isContainer && cfg.datasets != [] && servers != {};
      defaultText = "Enabled for IDR machines with ZFS pools when the team has backup servers.";
      description = "Create the backup account and authorize read-only ZFS replication.";
    };
    datasets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.attrNames pools;
      defaultText = "The roots of the machine's Disko ZFS pools.";
      description = "Dataset roots made available for recursive backup.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${user} = {};
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = "/var/empty";
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = map (member: "restrict ${member.sshPublicKey}") (lib.attrValues servers);
    };
    services.openssh = {
      enable = true;
      extraConfig = ''
        Match User ${user}
          SetEnv PATH=/run/booted-system/sw/bin:/run/current-system/sw/bin
        Match all
      '';
    };

    systemd.services.idr-backup-access = {
      description = "Authorize read-only ZFS replication for backup servers";
      wantedBy = ["multi-user.target" "sysinit-reactivation.target"];
      after = ["zfs.target" "systemd-sysusers.service" "userborn.service"];
      before = ["sanoid.service"];
      partOf = ["sysinit-reactivation.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${access} allow";
        ExecStop = "${access} unallow";
      };
    };

    system.build.idr.meta.backup = {
      inherit user;
      inherit (cfg) datasets;
      port = builtins.head config.services.openssh.ports;
      networkPrefix = config.idr.qemu.networkPrefix or null;
    };
  };
}

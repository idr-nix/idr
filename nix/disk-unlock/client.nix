top: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.disk-unlock.client;
  servers = lib.filterAttrs (name: member:
    name
    != config.idr.disk-unlock.server.member
    && builtins.elem "unlock-server" (member.groups or []))
  top.idr-lib.team;
  requestName = "${config.networking.hostName}-${config.idr.preset.base.id}";
in {
  options.idr.disk-unlock.client = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default =
        (config.idr.preset.base.enable or false)
        && !config.boot.isContainer
        && config.idr.preset.base.preFormatFiles ? "/disk-key.txt"
        && servers != {};
      defaultText = "Enabled for encrypted IDR machines when the team has other unlock servers.";
      description = "Whether to request disk unlocking from the team's unlock servers during initrd.";
    };
    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Seconds between unlock requests while in initrd.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.initrd = {
      network = {
        enable = true;
        ssh = {
          enable = true;
          authorizedKeys =
            config.users.users.root.openssh.authorizedKeys.keys
            ++ map (member: "restrict ${member.sshPublicKey}") (lib.attrValues servers);
        };
      };
      systemd = {
        enable = true;
        users.root.shell = "/bin/systemd-tty-ask-password-agent";
        storePaths = ["${pkgs.netcat-openbsd}/bin/nc"];
        services = lib.mapAttrs' (name: member:
          lib.nameValuePair "idr-request-disk-unlock-${name}" {
            description = "Request disk unlocking from ${name}";
            after = ["sshd.service"];
            before = ["initrd-switch-root.target"];
            conflicts = ["initrd-switch-root.target"];
            unitConfig = {
              DefaultDependencies = false;
              ConditionCredential = "!idr.workspace-id";
            };
            serviceConfig = {
              Type = "oneshot";
              TimeoutStartSec = 10;
            };
            script = ''
              printf '%s\n' ${lib.escapeShellArg requestName} |
                ${pkgs.netcat-openbsd}/bin/nc -N -w 5 ${lib.escapeShellArg member.hostname} ${toString (member.port or 64998)}
            '';
          })
        servers;
        timers = lib.mapAttrs' (name: _:
          lib.nameValuePair "idr-request-disk-unlock-${name}" {
            description = "Retry disk-unlock requests to ${name}";
            wantedBy = ["initrd.target"];
            before = ["initrd-switch-root.target"];
            conflicts = ["initrd-switch-root.target"];
            unitConfig = {
              DefaultDependencies = false;
              ConditionCredential = "!idr.workspace-id";
            };
            timerConfig = {
              OnBootSec = 0;
              OnUnitInactiveSec = "${toString cfg.interval}s";
              AccuracySec = "1s";
            };
          })
        servers;
      };
    };
  };
}

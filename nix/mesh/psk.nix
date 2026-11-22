{
  meshExe,
  meshServices,
}: {
  config,
  lib,
  options,
  ...
}: let
  cfg = config.idr.mesh;
  # Restarting a PSK secret restarts this unit, so netd reads the new secret.
  applyServices = name: service: {
    "idr-mesh-apply@${name}" = {
      overrideStrategy = "asDropin";
      wants = service.pskTargets;
      after = service.pskTargets;
      partOf = service.pskTargets;
      restartTriggers = [service.settingsFile];
    };
  };
in {
  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.optionalAttrs (options.environment ? persistence) {
      environment.persistence = lib.mkIf (config.idr.preset.impermanence.enable or false) {
        ${config.idr.preset.impermanence.persistDir or "/persist"}.directories = [
          {
            directory = "/var/lib/idr-mesh-psk";
            user = "root";
            group = "root";
            mode = "0700";
          }
        ];
      };
    })
    {
      # Each workload's ID and declared peers, with the paths of their PSKs.
      environment.etc = lib.mapAttrs' (name: service:
        lib.nameValuePair "idr-mesh/settings/${name}.json" {source = service.settingsFile;})
      meshServices;

      systemd.services =
        lib.concatMapAttrs applyServices meshServices
        // {
          "idr-mesh-apply@" = {
            description = "Apply mesh secrets and declarations for %i";
            bindsTo = ["%i.service"];
            requires = ["idr-mesh-netns@%i.service"];
            after = ["idr-mesh-netns@%i.service"];
            unitConfig = {
              StartLimitIntervalSec = 0;
              StopWhenUnneeded = true;
            };
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${meshExe} ctl apply %i";
              Restart = "on-failure";
              RestartSec = "5s";
              CapabilityBoundingSet = "";
              NoNewPrivileges = true;
            };
          };
        };
    }
  ]);
}

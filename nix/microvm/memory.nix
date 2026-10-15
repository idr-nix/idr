{
  lib,
  pkgs,
  src,
  vms,
  settings,
}: let
  package = pkgs.callPackage ./hypeman-package.nix {inherit src;};
  mib = 1024 * 1024;
  second = 1000000000;
  controllerConfig = pkgs.writeText "microvm-memory.json" (builtins.toJSON {
    inherit vms;
    apiTimeout = 2 * second;
    activeBallooning = {
      Enabled = true;
      PollInterval = settings.intervalSeconds * second;
      PressureHighWatermarkAvailablePercent = settings.reclaimBelowPercent;
      PressureLowWatermarkAvailablePercent = settings.releaseAbovePercent;
      ProtectedFloorPercent = settings.protectedFloorPercent;
      ProtectedFloorMinBytes = settings.protectedFloorMiB * mib;
      MinAdjustmentBytes = settings.minAdjustmentMiB * mib;
      PerVMMaxStepBytes = settings.stepMiB * mib;
      PerVMCooldown = settings.cooldownSeconds * second;
    };
  });
in {
  inherit package;

  assertions = [
    {
      assertion = settings.reclaimBelowPercent < settings.releaseAbovePercent;
      message = "microvm.memory.reclaimBelowPercent must be smaller than releaseAbovePercent.";
    }
    {
      assertion = settings.minAdjustmentMiB <= settings.stepMiB;
      message = "microvm.memory.minAdjustmentMiB cannot exceed stepMiB.";
    }
  ];

  service = {
    description = "Hypeman memory controller for microvm.nix guests";
    wantedBy = ["multi-user.target"];
    after = ["microvms.target"];
    restartIfChanged = true;
    unitConfig.ConditionCredential = "!idr.workspace-id";
    serviceConfig = {
      User = "microvm";
      Group = "kvm";
      ExecStart = "${lib.getExe package} --config ${controllerConfig}";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      # Hypeman persists targets next to each API socket under /run. Those
      # directories can appear after this service starts; Unix permissions
      # restrict writes to the microvm user's runtime files.
      ReadWritePaths = ["/run"];
      RestrictAddressFamilies = ["AF_UNIX"];
      PrivateDevices = true;
      CapabilityBoundingSet = "";
      SyslogIdentifier = "microvm-memory";
    };
  };
}

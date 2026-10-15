{lib}: let
  inherit (lib) mkOption types;
  percent = types.ints.between 1 99;
in {
  reclaimBelowPercent = mkOption {
    type = percent;
    default = 3;
    description = "Start Hypeman reclamation below this percentage of available host RAM. Host memory pressure stalls can also trigger reclamation.";
  };
  releaseAbovePercent = mkOption {
    type = percent;
    default = 5;
    description = "Return to gradual balloon deflation when available host RAM reaches this percentage and pressure stalls have cleared.";
  };
  protectedFloorPercent = mkOption {
    type = percent;
    default = 4;
    description = "Percentage of each running VM's memory ceiling protected from reclamation. Hypeman uses the larger of this and protectedFloorMiB, capped at the VM ceiling.";
  };
  protectedFloorMiB = mkOption {
    type = types.ints.positive;
    default = 512;
    description = "Shared absolute guest memory floor. Together with protectedFloorPercent it must cover each managed VM's running minimumMiB; otherwise that VM is excluded and an error is logged.";
  };
  stepMiB = mkOption {
    type = types.ints.positive;
    default = 256;
    description = "Maximum ordinary balloon adjustment per VM and policy iteration.";
  };
  minAdjustmentMiB = mkOption {
    type = types.ints.positive;
    default = 64;
    description = "Minimum target difference before Hypeman changes a VM's balloon.";
  };
  intervalSeconds = mkOption {
    type = types.ints.positive;
    default = 2;
    description = "Host pressure sampling and balloon policy interval.";
  };
  cooldownSeconds = mkOption {
    type = types.ints.positive;
    default = 5;
    description = "Minimum interval between ordinary balloon changes for the same VM.";
  };
}

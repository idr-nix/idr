top: moduleArgs @ {
  inputs,
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
in {
  options.idr.preset.base = {
  };

  config = lib.mkIf cfg.base.enable (lib.mkMerge [
    {
      systemd.settings.Manager = {
        DefaultRestartSec = lib.mkDefault "5s";
        DefaultStartLimitIntervalSec = lib.mkDefault "0";
        DefaultTimeoutStartSec = lib.mkDefault "90s";
        DefaultTimeoutStopSec = lib.mkDefault "90s";
        DefaultTimeoutAbortSec = lib.mkDefault "90s";
      };
    }
  ]);
}

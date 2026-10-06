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
    (lib.mkIf (!config.boot.isContainer) {
      systemd.services = lib.listToAttrs (map (swap:
        lib.nameValuePair "mkswap-${swap.deviceName}" {
          # The mapper's first udev probe can precede mkswap, leaving its
          # systemd device unready. Probe again once the swap signature exists.
          postStart = lib.mkAfter ''
            ${pkgs.systemd}/bin/udevadm trigger --action=change ${lib.escapeShellArg (toString swap.realDevice)}
          '';
        }) (builtins.filter
        (swap: swap.randomEncryption.enable && lib.hasPrefix "/dev/" swap.device)
        config.swapDevices));
    })
  ]);
}

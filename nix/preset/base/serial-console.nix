top: moduleArgs @ {
  config,
  lib,
  ...
}: let
  cfg = config.idr.preset;
in {
  options.idr.preset.base.serialConsole.enable = lib.mkOption {
    description = ''
      Whether to enable a serial console on ttyS0.
    '';
    type = lib.types.bool;
    default = true;
  };

  config = lib.mkIf (cfg.base.enable && cfg.base.serialConsole.enable && !config.boot.isContainer) {
    # systemd-getty-generator starts serial-getty@ttyS0 for the kernel console.
    boot.kernelParams = lib.mkAfter [
      "console=tty0"
      "console=ttyS0,115200n8"
    ];
  };
}

top: moduleArgs @ {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.preset;
in {
  options.idr.preset.base.serialConsole = {
    enable = lib.mkOption {
      description = ''
        Whether to enable a serial console.
      '';
      type = lib.types.bool;
      default = true;
    };
    device = lib.mkOption {
      description = ''
        Serial console device. The aarch64 default is the PL011 UART used by
        QEMU's virt machine and many ARM servers.
      '';
      type = lib.types.str;
      default =
        if pkgs.stdenv.hostPlatform.isAarch64
        then "ttyAMA0"
        else "ttyS0";
      defaultText = lib.literalExpression ''if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0"'';
    };
  };

  config = lib.mkIf (cfg.base.enable && cfg.base.serialConsole.enable && !config.boot.isContainer) {
    # systemd-getty-generator starts a serial getty for the kernel console.
    boot.kernelParams = lib.mkAfter [
      "console=tty0"
      "console=${cfg.base.serialConsole.device},115200n8"
    ];
  };
}

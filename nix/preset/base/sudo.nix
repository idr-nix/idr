top: moduleArgs @ {
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
      security.sudo.enable = lib.mkDefault false;
      security.sudo-rs = {
        enable = lib.mkDefault true;
        execWheelOnly = lib.mkDefault true;
      };
    }
  ]);
}

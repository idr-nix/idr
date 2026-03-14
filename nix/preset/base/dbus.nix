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
    # dbus
    {
      services.dbus.implementation = lib.mkDefault "broker";
    }
  ]);
}

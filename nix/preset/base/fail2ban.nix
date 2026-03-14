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
    # fail2ban
    {
      services.fail2ban.enable = lib.mkDefault (!config.boot.isContainer);
    }
  ]);
}

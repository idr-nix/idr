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
    # auditd
    (lib.mkIf (!config.boot.isContainer) {
      security.audit = {
        enable = lib.mkDefault true;
      };
      security.auditd = {
        enable = lib.mkDefault true;
      };
      services.journald.audit = lib.mkDefault true;
    })
  ]);
}

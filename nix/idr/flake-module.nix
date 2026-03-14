top: {
  inputs,
  lib,
  config,
  flake-parts-lib,
  ...
}: let
  cfg = config.idr;
in {
  imports = lib.attrValues (top.idr-lib.importFlakeModules ./. top);

  options.idr = {
    projectName = lib.mkOption {
      description = ''
        Project name
      '';
      type = lib.types.str;
    };
  };

  options.perSystem = flake-parts-lib.mkPerSystemOption ({
    config,
    system,
    pkgs,
    ...
  }: {
    formatter = lib.mkDefault pkgs.alejandra;
  });
}

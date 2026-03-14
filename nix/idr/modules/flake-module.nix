top: args @ {
  lib,
  config,
  self,
  inputs,
  flake-parts-lib,
  ...
}: let
  inherit (lib) mkOption types;
in {
  imports = [
    top.inputs.flake-parts.flakeModules.modules
  ];

  flake.nixosModules = config.flake.modules.nixos;
  flake.modules = {
    nixos = {};
    flake = {};
    devshell.idr = lib.modules.importApply ./devshell.nix top;
    homeManager = {};
    darwin = {};
    service = {};
    generic = {};
  };
}

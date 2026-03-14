top: moduleArgs @ {
  inputs,
  lib,
  config,
  flake-parts-lib,
  ...
}: {
  flake.modules.devshell.idr = flake-parts-lib.importApply ./devshell.nix top;

  perSystem = {pkgs, ...}: {
    checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
      nixos-project-tools = import ./checks/project-tools/test.nix {
        inherit pkgs;
        inherit (top) inputs self;
      };
    };
  };
}

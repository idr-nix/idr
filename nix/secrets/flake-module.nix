top: {
  lib,
  config,
  self,
  inputs,
  flake-parts-lib,
  ...
}: {
  flake.modules.nixos.secrets = lib.modules.importApply ./nixos-module.nix top;

  perSystem = {pkgs, ...}: {
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      nixos-secret-services = import ./checks/services.nix {
        inherit pkgs;
        inherit (top) inputs self;
      };
    };
  };
}

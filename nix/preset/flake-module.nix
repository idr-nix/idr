top: {
  lib,
  config,
  inputs,
  flake-parts-lib,
  ...
}: {
  flake.modules.nixos.preset = flake-parts-lib.importApply ./nixos-module.nix top;

  perSystem = {pkgs, ...}: {
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      nixos-base-presets = import ./base/checks/defaults.nix {
        inherit pkgs;
        inherit (top) inputs self;
      };
      nixos-container-reload = import ./base/checks/container-reload.nix {
        inherit pkgs;
        inherit (top) inputs self;
      };
      nixos-disk-key-rotation = import ./base/checks/key-rotation.nix {
        inherit pkgs;
        inherit (top) inputs self;
      };
    };
  };
}

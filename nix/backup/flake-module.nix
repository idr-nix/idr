top: {lib, ...}: {
  flake.modules.nixos.backup = lib.modules.importApply ./nixos-module.nix top;

  perSystem = {pkgs, ...}: {
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      nixos-backups = import ./checks/backups.nix {
        inherit pkgs;
        inherit (top) inputs self;
      };
    };
  };
}

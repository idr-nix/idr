top: {lib, ...}: {
  flake.modules.nixos.disk-unlock = lib.modules.importApply ./nixos-module.nix top;
  flake.modules.devshell.idr = {pkgs, ...}: {
    idr.additionalPaths = [pkgs.netcat-openbsd];
  };

  perSystem = {pkgs, ...}: {
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      nixos-auto-unlock = import ./checks/auto-unlock.nix {
        inherit pkgs;
        inherit (top) inputs self;
      };
    };
  };
}

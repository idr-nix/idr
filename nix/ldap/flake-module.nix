top: {lib, ...}: {
  flake.modules.nixos.ldap = lib.modules.importApply ./nixos-module.nix top;

  perSystem = {pkgs, ...}: {
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      nixos-ldap = import ./checks/server.nix {
        inherit pkgs;
        inherit (top) inputs self;
      };
    };
  };
}

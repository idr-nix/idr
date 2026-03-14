top: {lib, ...}: {
  flake.modules.nixos.etcd = lib.modules.importApply ./nixos-module.nix top;

  perSystem = {pkgs, ...}: {
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      nixos-etcd = import ./checks/cluster.nix {
        inherit pkgs;
        inherit (top) inputs self;
      };
    };
  };
}

top: {lib, ...}: {
  flake.modules.nixos.etcd = lib.modules.importApply ./nixos-module.nix top;
}

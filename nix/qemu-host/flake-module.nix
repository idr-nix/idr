top: {lib, ...}: {
  flake.modules.nixos.qemu-host = lib.modules.importApply ./nixos-module.nix top;
}

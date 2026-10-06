top: {lib, ...}: {
  flake.modules.nixos.backup = lib.modules.importApply ./nixos-module.nix top;
}

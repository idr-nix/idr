top: {lib, ...}: {
  flake.modules.nixos.microvm = lib.modules.importApply ./nixos-module.nix top;
  flake.modules.nixos.microvm-guest = lib.modules.importApply ./guest.nix top;
}

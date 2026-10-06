top: {lib, ...}: {
  flake.modules.nixos.certs = lib.modules.importApply ./nixos-module.nix top;
}

top: {lib, ...}: {
  flake.modules.nixos.secrets = lib.modules.importApply ./nixos-module.nix top;
}

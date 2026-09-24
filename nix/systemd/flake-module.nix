top: {lib, ...}: {
  flake.modules.nixos.systemd = lib.modules.importApply ./nixos-module.nix top;
}

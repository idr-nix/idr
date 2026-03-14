top: {lib, ...}: {
  flake.modules.devshell.idr = lib.modules.importApply ./devshell.nix top;
}

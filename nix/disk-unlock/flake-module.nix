top: {lib, ...}: {
  flake.modules.nixos.disk-unlock = lib.modules.importApply ./nixos-module.nix top;
  flake.modules.devshell.idr = {pkgs, ...}: {
    idr.additionalPaths = [pkgs.netcat];
  };
}

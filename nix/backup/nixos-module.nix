top: {lib, ...}: {
  key = toString ./nixos-module.nix;

  imports = map (file: lib.modules.importApply file top) [
    ./client.nix
    ./server.nix
    ./snapshots.nix
  ];
}

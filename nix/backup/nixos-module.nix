top: {lib, ...}: {
  imports = map (file: lib.modules.importApply file top) [
    ./client.nix
    ./server.nix
    ./snapshots.nix
  ];
}

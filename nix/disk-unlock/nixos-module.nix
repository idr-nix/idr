top: {lib, ...}: {
  imports = map (path: lib.modules.importApply path top) [
    ./client.nix
    ./server.nix
  ];
}

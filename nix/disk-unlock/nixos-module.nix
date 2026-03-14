top: {lib, ...}: {
  key = toString ./nixos-module.nix;

  imports = map (path: lib.modules.importApply path top) [
    ./client.nix
    ./server.nix
  ];
}

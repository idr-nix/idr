top: {lib, ...}: {
  flake.modules.nixos.ldap = lib.modules.importApply ./nixos-module.nix top;
}

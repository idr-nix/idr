top: {lib, ...}: {
  flake.modules.nixosTest = {
    nix = lib.modules.importApply ./nix.nix top;
    nix-store = lib.modules.importApply ./nix-store.nix top;
    operator = lib.modules.importApply ./operator.nix top;
    ssh-git = lib.modules.importApply ./ssh-git.nix top;
  };
}

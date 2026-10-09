top: {lib, ...}: let
  importTestModule = path: {
    # Catalog consumers can import both base and its individual modules.
    key = toString path;
    imports = [(lib.modules.importApply path top)];
  };
in {
  flake.modules.nixosTest = {
    base = importTestModule ./base.nix;
    direnv = importTestModule ./direnv.nix;
    disk-storage = importTestModule ./disk-storage.nix;
    kvm-clock = importTestModule ./kvm-clock.nix;
    nix = importTestModule ./nix.nix;
    nix-store = importTestModule ./nix-store.nix;
    operator = importTestModule ./operator.nix;
    ssh-git = importTestModule ./ssh-git.nix;
  };
}

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    checks.local-vm-rollback = import ./local-vm-deployed-rollback-test.nix {
      inherit top lib pkgs;
      project = config.checks.local-vm-persistence;
      automatic = false;
    };
  };
}

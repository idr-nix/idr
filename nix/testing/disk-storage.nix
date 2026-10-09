_: {lib, ...}: {
  # Test artifacts can exceed RAM (for example, exported Nix closures and VM
  # images). Keep temporary files and writable stores on the test's disks.
  defaults.boot.tmp.useTmpfs = lib.mkForce false;

  nodeDefaults.virtualisation = {
    writableStoreUseTmpfs = lib.mkForce false;
    # QEMU creates a sparse image; only written blocks occupy host disk space.
    diskSize = lib.mkDefault (32 * 1024);
  };

  containerDefaults = {
    config,
    pkgs,
    ...
  }: {
    # nspawn mounts its own /tmp tmpfs independently of boot.tmp.useTmpfs.
    # A source relative to the container root keeps every container private,
    # including when the driver overrides rootDir with RUN_NSPAWN_ROOT_DIR.
    config.virtualisation.systemd-nspawn.options = [
      "--bind=+/var/tmp/idr-test-tmp:/tmp"
    ];
    options.system.build.nspawn = lib.mkOption {
      type = lib.types.package;
      internal = true;
      description = "Container launcher with a private disk-backed temporary directory.";
      apply = launcher:
        pkgs.writers.writeDashBin "run-${config.system.name}-nspawn" ''
          set -eu
          root_dir="''${RUN_NSPAWN_ROOT_DIR:-}"
          if [ -z "$root_dir" ]; then
            root_dir=${lib.escapeShellArg config.virtualisation.rootDir}
          fi
          ${pkgs.coreutils}/bin/install -d -m 1777 "$root_dir/var/tmp/idr-test-tmp"
          exec ${launcher}/bin/run-${config.system.name}-nspawn "$@"
        '';
    };
  };
}

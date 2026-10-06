_: {
  hostPkgs,
  lib,
  ...
}: let
  inherit (hostPkgs.stdenv.hostPlatform) isLinux;
in {
  requiredFeatures.kvm = isLinux;
  # Linux can share KVM with nspawn. Darwin runs the same Linux commands in a
  # NixOS VM; QEMU inside that guest falls back to TCG when KVM is unavailable.
  containers = lib.optionalAttrs isLinux {
    machine.virtualisation.systemd-nspawn.options = ["--bind=/dev/kvm"];
  };

  nodes = lib.optionalAttrs (!isLinux) {
    machine = {
      virtualisation = {
        cores = 4;
        memorySize = 6144;
        diskSize = 32 * 1024;
        # The guest also holds image files and the nested VM's memory.
        writableStoreUseTmpfs = lib.mkForce false;
      };
      networking.useDHCP = false;
      # TCG and virtiofs keep additional anonymous memory beside the nested
      # VM's RAM. Let the outer guest reclaim inactive pages during image copies.
      swapDevices = lib.mkVMOverride [
        {
          device = "/var/lib/idr-test.swap";
          size = 4096;
        }
      ];
      environment.variables = {
        IDR_QEMU_BUILD_MEMORY = "4096";
        NIX_BUILD_CORES = "2";
      };
      nix.settings = {
        cores = 2;
        max-jobs = 2;
        eval-cores = lib.mkForce 2;
      };
    };
  };
}

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
        # Leave room for IDR's normal 16 GiB image builder and the outer guest.
        memorySize = lib.mkDefault (20 * 1024);
        # Nix supplies the per-build CPU budget at runtime; zero means all cores.
        qemu.options = lib.mkAfter [
          ''-smp "$(if [ "''${NIX_BUILD_CORES:-0}" -gt 0 ]; then printf '%s' "$NIX_BUILD_CORES"; else ${lib.getExe' hostPkgs.coreutils "nproc"}; fi)"''
        ];
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
    };
  };
}

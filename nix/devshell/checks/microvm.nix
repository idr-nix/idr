top: {lib, ...}: {
  imports = [(lib.modules.importApply ./microvm-network.nix top) ./microvm-provisioning.nix];

  perSystem = {pkgs, ...}: {
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
      lib.genAttrs ["microvm-storage" "microvm-storage-raw" "microvm-storage-qcow2" "microvm-storage-block" "microvm-storage-mixed" "microvm-memory" "microvm-deployment" "microvm-lifecycle" "microvm-management" "microvm-activation" "microvm-recreation"] (name:
        pkgs.testers.runNixOSTest (
          import ./microvm-fixture.nix top (lib.removePrefix "microvm-" name)
        ))
    );
  };
}

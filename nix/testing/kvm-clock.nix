_: {
  config,
  hostPkgs,
  lib,
  ...
}: {
  nodeDefaults = {pkgs, ...}: {
    # Nested KVM can read its paravirtual clock without emulated ACPI I/O.
    boot.kernelParams = lib.mkIf (
      hostPkgs.stdenv.hostPlatform.isLinux
      && hostPkgs.stdenv.hostPlatform.isx86_64
      && config.requiredFeatures.kvm
      && pkgs.stdenv.hostPlatform.isx86_64
    ) (lib.mkAfter ["clocksource=kvm-clock"]);
  };
}

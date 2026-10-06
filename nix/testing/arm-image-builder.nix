_: {
  hostPkgs,
  lib,
  ...
}: let
  guestPkgs = hostPkgs.pkgsLinux;
  qemu =
    (import (guestPkgs.path + "/nixos/lib/qemu-common.nix") {
      inherit lib;
      stdenv = guestPkgs.stdenv;
    }).qemuBinary
    guestPkgs.qemu_kvm;
  imageBuilderQemu = guestPkgs.writeShellScript "nixos-test-image-builder-qemu" ''
    if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
      # EDK2 202602 stalls before booting the image builder with TCG's LPA2.
      exec ${guestPkgs.qemu_kvm}/bin/qemu-system-aarch64 \
        -machine virt,gic-version=max,accel=tcg -cpu max,lpa2=off "$@"
    fi
    exec ${qemu} "$@"
  '';
in {
  # The bootloader image is built on a Linux builder, which can itself be a VM
  # without nested KVM. This only changes the helper used to build its image.
  node.pkgs = lib.mkIf guestPkgs.stdenv.hostPlatform.isAarch64 (lib.mkForce (guestPkgs
    // {
      vmTools = guestPkgs.vmTools.override {customQemu = toString imageBuilderQemu;};
    }));
}

top: {
  lib,
  flake-parts-lib,
  ...
}: {
  flake.modules.nixos.preset = flake-parts-lib.importApply ./nixos-module.nix top;

  perSystem = {pkgs, ...}: {
    legacyPackages.idrQemuBuilders = {
      inherit (pkgs) writeShellApplication writeText;
    };

    packages = let
      imageBuildVm = pkgs.callPackage ./base/qemu/image-build-vm.nix {
        inherit (top.inputs.nixpkgs.lib) nixosSystem;
        linuxSystem = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux";
      };
    in
      {
        idr-qemu-runtime = pkgs.callPackage ./base/qemu/runtime.nix {
          imageBuildVm = lib.optionalDrvAttr pkgs.stdenv.hostPlatform.isDarwin imageBuildVm;
        };
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        idr-qemu-image-build-vm = imageBuildVm;
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        idr-qemu-firmware = pkgs.callPackage ./base/qemu/firmware.nix {};
        idr-qemu-installer = import ./base/qemu/installer.nix {
          inherit pkgs;
          nixosImages = top.inputs.nixos-images;
        };
      };
  };
}

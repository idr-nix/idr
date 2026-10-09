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
      # Resolve the Linux guest only when image building is requested, so the
      # native Darwin runtime and default shell do not require a Linux builder.
      imageBuildVmLauncher =
        pkgs.writers.writeNuBin "idr-qemu-image-build-vm" {
          makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.nix pkgs.vfkit])];
        } ''
          def --wrapped main [...args: string] {
            exec ${lib.getExe pkgs.nix} -L run ${lib.escapeShellArg "${top.self}#idr-qemu-image-build-vm"} -- ...$args
          }
        '';
    in
      {
        idr-qemu-runtime = pkgs.callPackage ./base/qemu/runtime.nix {
          imageBuildVm = lib.optionalDrvAttr pkgs.stdenv.hostPlatform.isDarwin imageBuildVmLauncher;
        };
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        idr-qemu-image-build-vm = imageBuildVm;
        idr-qemu-image-build-vm-launcher = imageBuildVmLauncher;
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

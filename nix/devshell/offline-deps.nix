{
  lib,
  pkgs,
  idr,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  closure = name: paths:
    pkgs.linkFarm name {
      dependencies = pkgs.writeClosure paths;
    };
in
  {
    documentation-inputs = closure "idr-offline-documentation-inputs" (
      [idr.packages.${system}.idr-nix-search-tv-config]
      ++ lib.optional (idr.packages.${system} ? idr-generate-docs) idr.packages.${system}.idr-generate-docs
    );
  }
  // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (let
    machine = idr.nixosConfigurations."example-${system}";
    build = machine.config.system.build;
    installer = idr.packages.${system}.idr-qemu-installer;
  in {
    nixos-image = closure "idr-offline-nixos-image" (
      [installer idr.packages.${system}.idr-qemu-firmware]
      ++ installer.offlineDependencies
    );
    example-machine = closure "idr-offline-example-machine" (
      [
        build.toplevel
        build.toplevel.inputDerivation
        build.diskoImagesScript
        (lib.getDev machine.pkgs.buildPackages.kmod)
      ]
      ++ lib.optional (build ? idrQemu) build.idrQemu
    );
  })

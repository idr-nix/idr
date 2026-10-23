{
  lib,
  pkgs,
  idr,
}:
lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (let
  inherit (pkgs.stdenv.hostPlatform) system;
  machine = idr.nixosConfigurations."example-${system}";
  build = machine.config.system.build;
  installer = idr.packages.${system}.idr-qemu-installer;
  closure = name: paths:
    pkgs.linkFarm name {
      dependencies = pkgs.writeClosure paths;
    };
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

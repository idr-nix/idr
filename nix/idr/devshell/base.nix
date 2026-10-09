top: {
  lib,
  pkgs,
  ...
}: {
  # Keep native tools cached everywhere and Linux example builds on Linux hosts.
  idr.additionalPaths = let
    example = "example-${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux";
  in
    [pkgs.redis pkgs.fzf (lib.getMan pkgs.fzf)]
    ++ lib.optionals (pkgs.stdenv.hostPlatform.isLinux && top.self.nixosConfigurations ? ${example}) (let
      machine = top.self.nixosConfigurations.${example};
      build = machine.config.system.build;
    in
      [
        build.toplevel
        build.toplevel.inputDerivation
        build.diskoImagesScript
        # Initrd rebuilds request kmod's dev output through nativeBuildInputs.
        (lib.getDev machine.pkgs.buildPackages.kmod)
      ]
      ++ lib.optionals (build ? idrQemu) ([build.idrQemu] ++ build.idrQemu.installer.offlineDependencies));
}

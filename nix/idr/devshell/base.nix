top: {
  lib,
  pkgs,
  ...
}: {
  # Keep IDR's template outputs and build dependencies available for offline use.
  idr.additionalPaths = let
    example = "example-${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux";
  in
    lib.optionals (top.self.nixosConfigurations ? ${example}) (let
      build = top.self.nixosConfigurations.${example}.config.system.build;
    in
      [
        build.toplevel
        build.toplevel.inputDerivation
        build.diskoImagesScript
      ]
      ++ lib.optionals (build ? idrQemu) ([build.idrQemu] ++ build.idrQemu.installer.offlineDependencies));
}

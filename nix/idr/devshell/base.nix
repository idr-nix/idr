top: {
  lib,
  pkgs,
  ...
}: {
  # Keep IDR's template outputs and build dependencies available for offline use.
  idr.additionalPaths = lib.optionals (pkgs.stdenv.hostPlatform.system == "x86_64-linux") (let
    build = top.self.nixosConfigurations.example-x86_64-linux.config.system.build;
  in
    [
      build.toplevel
      build.toplevel.inputDerivation
      build.diskoImagesScript
    ]
    ++ lib.optionals (build ? idrQemu) ([build.idrQemu] ++ build.idrQemu.installer.offlineDependencies));
}

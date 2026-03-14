top: {
  inputs,
  lib,
  config,
  self,
  ...
}: {
  flake.nixosConfigurations."example-x86_64-linux" = with inputs.nixpkgs.lib;
    makeOverridable nixosSystem {
      system = "x86_64-linux";
      modules = top.idr-lib.importApplyAll top [./configuration.nix];
    };

  flake.modules.devshell.idr = {pkgs, ...}: {
    # Seed downstream shells with the template's build dependencies for offline use.
    idr.additionalPaths = lib.optionals (pkgs.stdenv.hostPlatform.system == "x86_64-linux") (let
      build = self.nixosConfigurations.example-x86_64-linux.config.system.build;
    in
      [
        build.toplevel
        build.toplevel.inputDerivation
        build.diskoImagesScript
      ]
      ++ lib.optionals (build ? idrQemu) ([build.idrQemu] ++ build.idrQemu.installer.offlineDependencies));
  };
}

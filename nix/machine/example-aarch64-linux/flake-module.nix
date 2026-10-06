top: {
  inputs,
  lib,
  config,
  self,
  ...
}: {
  flake.nixosConfigurations."example-aarch64-linux" = with inputs.nixpkgs.lib;
    makeOverridable nixosSystem {
      system = "aarch64-linux";
      modules = top.idr-lib.importApplyAll top [./configuration.nix];
    };
}

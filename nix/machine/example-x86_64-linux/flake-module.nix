top: {inputs, ...}: {
  flake.nixosConfigurations."example-x86_64-linux" = with inputs.nixpkgs.lib;
    makeOverridable nixosSystem {
      system = "x86_64-linux";
      modules = top.idr-lib.importApplyAll top [./configuration.nix];
    };
}

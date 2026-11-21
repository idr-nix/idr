top: {lib, ...}: {
  imports = [
    top.inputs.treefmt-nix.flakeModule
  ];

  perSystem = {config, ...}: {
    treefmt = {
      projectRootFile = "flake.nix";
      programs = {
        alejandra.enable = true;
        fourmolu.enable = true;
        cabal-fmt.enable = true;
      };
      flakeCheck = false;
    };

    formatter = config.treefmt.build.wrapper;

    devshells.default.packages =
      [config.treefmt.build.wrapper]
      ++ lib.attrValues config.treefmt.build.programs;
  };
}

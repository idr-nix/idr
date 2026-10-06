{
  description = "An existing flake-parts project";

  inputs = {
    idr = {
      url = "git+ssh://git@github.com/idr-nix/idr?shallow=1";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-unstable.follows = "nixpkgs-unstable";
        systems.follows = "systems";
        team.follows = "team";
      };
    };
    team = {
      url = "file+file:///dev/null";
      flake = false;
    };
    nixpkgs.url = "git+ssh://git@github.com/NixOS/nixpkgs?shallow=1&ref=nixos-26.05";
    nixpkgs-unstable.url = "git+ssh://git@github.com/NixOS/nixpkgs?shallow=1&ref=nixos-unstable";
    flake-parts.url = "git+ssh://git@github.com/hercules-ci/flake-parts?shallow=1";
    systems.url = "git+ssh://git@github.com/nix-systems/default?shallow=1";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} (top @ {
      config,
      lib,
      ...
    }: let
      flakeModules = inputs.idr.lib.importFlakeModules ./nix top;
    in {
      idr.projectName = "existing-project";
      flake.modules.flake = flakeModules;
      imports =
        [./existing-module.nix]
        ++ (inputs.nixpkgs.lib.attrValues flakeModules)
        ++ [inputs.idr.modules.flake.idr];

      systems = import inputs.systems;
      flake.preservedCallback = lib.concatStringsSep ":" ["existing" config.flake.preservedImport];
    });
}

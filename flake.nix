{
  description = "Infrastructure done right";
  outputs = inputs @ {
    self,
    flake-parts,
    nixpkgs,
    ...
  }: let
    idr-lib = import ./nix/lib/lib.nix {
      inherit (nixpkgs) lib;
      inherit (inputs) team;
    };
  in
    flake-parts.lib.mkFlake {inputs = inputs // {idr = self;};} (top @ {
      config,
      withSystem,
      moduleWithSystem,
      ...
    }: let
      flakeModules = idr-lib.importFlakeModules ./nix top;
    in {
      idr.projectName = "idr";
      flake.lib = idr-lib;
      flake.modules.flake = flakeModules;
      flake.modules.nixos = {
        disko = inputs.disko.nixosModules.disko;
        disko-zfs = inputs.disko-zfs.nixosModules.default;
        sops = inputs.sops-nix.nixosModules.sops;
        impermanence = inputs.impermanence.nixosModules.impermanence;
      };
      imports = (nixpkgs.lib.attrValues flakeModules) ++ [];
      systems = import inputs.systems;

      perSystem = {
        pkgs,
        system,
        lib,
        ...
      }: {
        idr.documentation.assets = ["LICENSE"];
        idr.documentation.nixdoc.libs = [
          {
            path = "${self}/nix/lib/lib.nix";
            prefix = "lib";
          }
        ];
      };
    });
  inputs = {
    team = {
      url = "file+file:///dev/null";
      flake = false;
    };

    nixpkgs.url = "git+ssh://git@github.com/NixOS/nixpkgs?shallow=1&ref=nixos-26.05";

    nixpkgs-unstable.url = "git+ssh://git@github.com/NixOS/nixpkgs?shallow=1&ref=nixos-unstable";

    flake-parts.url = "git+ssh://git@github.com/hercules-ci/flake-parts?shallow=1";

    systems.url = "git+ssh://git@github.com/nix-systems/default?shallow=1";

    devshell = {
      url = "git+ssh://git@github.com/numtide/devshell?shallow=1";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    deploy-rs = {
      url = "git+ssh://git@github.com/serokell/deploy-rs?shallow=1";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    nixos-images = {
      url = "git+ssh://git@github.com/nix-community/nixos-images?shallow=1";
      inputs = {
        nixos-stable.follows = "nixpkgs";
        nixos-unstable.follows = "nixpkgs-unstable";
      };
    };

    disko = {
      url = "git+ssh://git@github.com/nix-community/disko?shallow=1";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    disko-zfs = {
      url = "git+ssh://git@github.com/numtide/disko-zfs?shallow=1";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
        disko.follows = "disko";
      };
    };

    sops-nix = {
      url = "git+ssh://git@github.com/Mic92/sops-nix?shallow=1";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    impermanence = {
      url = "git+ssh://git@github.com/nix-community/impermanence?shallow=1";
      inputs = {
        home-manager.follows = "home-manager";
        nixpkgs.follows = "nixpkgs";
      };
    };

    home-manager = {
      url = "git+ssh://git@github.com/nix-community/home-manager?shallow=1&ref=release-26.05";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    git-hooks-nix = {
      url = "git+ssh://git@github.com/cachix/git-hooks.nix?shallow=1";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    process-compose-flake.url = "git+ssh://git@github.com/Platonic-Systems/process-compose-flake?shallow=1";

    services-flake.url = "git+ssh://git@github.com/juspay/services-flake?shallow=1";
  };
}

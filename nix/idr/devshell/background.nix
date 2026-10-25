{
  idr,
  project,
  system,
  documentation,
  searchOptions,
}: {
  lib,
  pkgs,
  ...
}: let
  idrSource = import ./offline-source.nix {
    inherit lib pkgs;
    inherit idr;
  };
  projectSource = import ./offline-source.nix {
    inherit lib pkgs;
    idr = project;
  };
  jobs =
    lib.genAttrs (builtins.attrNames idr.legacyPackages.${system}.idrOfflineDependencies) (name: {
      source = toString idrSource;
      attribute = "packages.${system}.default.passthru.deps.${name}";
    })
    // lib.optionalAttrs documentation {
      documentation = {
        source = toString projectSource;
        attribute = "packages.${system}.idr-generate-docs";
        generateDocs = true;
      };
    }
    // lib.optionalAttrs searchOptions {
      search-options = {
        source = toString projectSource;
        attribute = "packages.${system}.idr-nix-search-tv-config";
      };
    };
  jobFile = pkgs.writeText "idr-background-builds.json" (builtins.toJSON jobs);
  builder =
    pkgs.writers.writeNuBin "idr-build-background" {
      makeWrapperArgs = [
        "--set"
        "IDR_BACKGROUND_BUILDS"
        "${jobFile}"
        "--prefix"
        "PATH"
        ":"
        (lib.makeBinPath ([pkgs.coreutils pkgs.daemonize pkgs.execline pkgs.flock] ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.procps))
      ];
    } ''
      source ${../../scripts/idr-build-background.nu}
    '';
in {
  env = [
    {
      name = "IDR_BACKGROUND_BUILD";
      value = lib.getExe builder;
    }
  ];
  devshell.startup.idr-build-background.text = ''
    ${lib.getExe builder} start
  '';
}

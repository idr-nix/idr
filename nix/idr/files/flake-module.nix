top: args @ {
  lib,
  config,
  self,
  inputs,
  flake-parts-lib,
  ...
}: let
  inherit (lib) mkOption types;
  scripts = ../../scripts;
in {
  options.perSystem = flake-parts-lib.mkPerSystemOption ({
    config,
    system,
    pkgs,
    ...
  }: {
    options.idr = {
      files = lib.mkOption {
        description = ''
          Files to be written for.
        '';
        default = {};
        example =
          lib.literalExpression
          # nix
          ''
            {
              "README.md" = {
                content =
                  pkgs.writeText "README.md"
                    # markdown
                    '''
                      # Practical Project

                      Clear documentation
                    ''';
              };
              ".gitignore" = {
                content = '''
                  result
                ''';
                postWrite = '''
                  chmod 0700 .gitignore
                ''';
                copy = true; # Copy file instead of symlink
              };
            }
          '';
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              content = lib.mkOption {
                description = ''
                  Provide the file as a derivation or string.
                '';
                type = lib.types.oneOf [lib.types.package lib.types.str];
                example =
                  lib.literalExpression
                  # nix
                  ''
                    pkgs.writers.writeJSON "gh-actions-workflow-check.yaml" {
                      on.push = { };
                      jobs.check = {
                        runs-on = "ubuntu-latest";
                        steps = [
                          { uses = "actions/checkout@v4"; }
                          { uses = "DeterminateSystems/nix-installer-action@main"; }
                          { uses = "DeterminateSystems/magic-nix-cache-action@main"; }
                          { run = "nix flake check"; }
                        ];
                      };
                    }
                  '';
              };
              postWrite = lib.mkOption {
                description = ''
                  Script to run after file modification.
                '';
                type = lib.types.lines;
                default = "";
              };
              copy = lib.mkOption {
                description = ''
                  Whether to copy a file instead of symlink.
                '';
                type = lib.types.bool;
                default = false;
              };
            };
          }
        );
      };
    };
    config = {
      devshells.default = {
        packages = [pkgs.coreutils];
        devshell.startup.idr-write-files.text = let
          files = lib.mapAttrs (k: v:
            v
            // {
              content =
                if (lib.types.package.check v.content)
                then v.content
                else pkgs.writeText k v.content;
            })
          config.idr.files;
        in ''
          export IDR_FILES_PATH="${pkgs.writeText "idr-files.json" (builtins.toJSON files)}"
          idr-with-project-lock nu -n --no-std-lib --no-history ${scripts}/idr-write-files.nu
        '';
      };
    };
  });
}

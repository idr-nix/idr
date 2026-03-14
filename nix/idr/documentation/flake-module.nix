top: moduleArgs @ {
  lib,
  config,
  inputs,
  self,
  flake-parts-lib,
  ...
}: let
  inherit (lib) mkOption types;
in {
  options.perSystem = flake-parts-lib.mkPerSystemOption ({
    config,
    system,
    pkgs,
    ...
  }: let
    moduleTypes = [
      {
        full = "nixos";
        short = "nixos";
      }
      {
        full = "flake";
        short = "flake";
      }
      {
        full = "devshell";
        short = "devshell";
      }
      {
        full = "homeManager";
        short = "home";
      }
      {
        full = "darwin";
        short = "darwin";
      }
      {
        full = "service";
        short = "service";
      }
      {
        full = "generic";
        short = "generic";
      }
    ];
    mkModuleDoc = {
      type,
      modules,
      source ? null,
    }: let
      evalModules =
        if type.full == "nixos" && source != null
        then args: inputs.nixpkgs.lib.nixosSystem (removeAttrs args ["class"] // {inherit system;})
        else lib.evalModules;
    in
      pkgs.nixosOptionsDoc {
        warningsAreErrors = false;
        transformOptions = option:
          option
          // lib.optionalAttrs (source != null) {
            visible =
              option.visible
              && lib.any (declaration: lib.hasPrefix "${source}/" (toString declaration)) option.declarations;
          };
        options =
          (evalModules {
            modules =
              map
              (module:
                if source == null
                then module
                else lib.setDefaultModuleLocation "${source}/flake.nix" module)
              (lib.unique modules)
              ++ [
                {
                  config._module.check = false;
                  options._module.args = lib.mkOption {
                    internal = true;
                  };
                }
              ];
            specialArgs =
              {
                inputs = {idr = top.self;} // inputs;
                idr-lib = top.idr-lib;
                modulesPath = "${inputs.nixpkgs}/nixos/modules";
              }
              // (lib.optionalAttrs (type.full == "flake") {
                flake-parts-lib =
                  flake-parts-lib
                  // {
                    mkPerSystemOption = prev:
                      if builtins.isFunction prev
                      then
                        flake-parts-lib.mkPerSystemOption (opts @ {
                          system,
                          config,
                          options,
                          extendModules,
                          ...
                        }:
                          prev (opts
                            // {
                              inherit pkgs;
                            }))
                      else flake-parts-lib.mkPerSystemOption prev;
                  };
              })
              // (cfg.specialArgs.${type.full} or {});
            class = type.full;
          }).options;
      };

    cfg = config.idr.documentation;
    perTypeDocs = lib.genAttrs' moduleTypes (type: let
      doc = mkModuleDoc {
        inherit type;
        modules = builtins.attrValues self.modules.${type.full};
      };
    in
      lib.nameValuePair type.full {
        md = doc.optionsCommonMark;
        json = doc.optionsJSON;
        adoc = doc.optionsAsciiDoc;
      });
    docs = lib.genAttrs' moduleTypes (
      type: lib.nameValuePair type.short perTypeDocs.${type.full}.md
    );
    json-docs = lib.genAttrs' moduleTypes (
      type:
        lib.nameValuePair "(${type.short})"
        "${perTypeDocs.${type.full}.json}/share/doc/nixos/options.json"
    );
    non-referential-inputs =
      lib.filterAttrs
      (
        name: input:
          !(builtins.elem name ["self"])
          && self.narHash != input.narHash
      )
      inputs;
    inputs-doc = pkgs.writeText "inputs.md" ''
      # Inputs
      ${lib.concatStringsSep "\n"
        (lib.flatten
          (lib.mapAttrsToList (
              name: input:
                (lib.optional
                  (input ? packages.${system}.idr-mk-docs)
                  "- [${name}](${input.packages.${system}.idr-mk-docs}/html/index.html)")
                ++ (
                  lib.optional
                  (input ? lib.nixosSystem)
                  (let
                    nixpkgsManual = "[nixpkgs manual](${input.htmlDocs.nixpkgsManual.${system}}/share/doc/nixpkgs/index.html)";
                    nixosManualPackage =
                      input.htmlDocs.nixosManual.${
                        system
                      }
                      or (input.lib.nixosSystem {
                        inherit system;
                        modules = [];
                      }).config.system.build.manual.manualHTML;
                    nixosManual = "[nixos manual](${nixosManualPackage}/share/doc/nixos/index.html)";
                  in "- ${name}: ${nixpkgsManual}, ${nixosManual}.")
                )
            )
            non-referential-inputs))}
    '';
    input-json-docs =
      lib.concatMapAttrs
      (name: input: let
        idr-input = input ? packages.${system}.idr-mk-docs;
        nixpkgs-input = input ? lib.nixosSystem;
        other-input = !(idr-input || nixpkgs-input);
      in
        (lib.optionalAttrs idr-input {
          ${name} = {
            inherit (input.packages.${system}.idr-mk-docs.passthru) json-docs input-json-docs;
          };
        })
        // (lib.optionalAttrs nixpkgs-input {
          ${name} = {
            json-docs = {
              "(nixos)" =
                (pkgs.nixosOptionsDoc {
                  warningsAreErrors = false;
                  options =
                    (input.lib.nixosSystem {
                      inherit system;
                      modules = [
                        ({
                          config,
                          lib,
                          ...
                        }: {
                          config._module.check = false;
                          config.system.stateVersion = config.system.nixos.release;
                          options._module.args = lib.mkOption {
                            internal = true;
                          };
                        })
                      ];
                    }).options;
                }).optionsJSON
                + "/share/doc/nixos/options.json";
            };
            input-json-docs = {};
          };
        })
        // (lib.optionalAttrs other-input {
          ${name} = {
            json-docs =
              lib.foldl'
              (
                acc: type:
                  acc
                  // (lib.optionalAttrs (input ? "${type.full}Module"
                    || input ? "${type.full}Modules"
                    || input ? modules.${type.full}
                    || (type.full == "homeManager" && input ? lib.homeManagerConfiguration)) {
                    "(${type.short})" =
                      if (type.full == "homeManager" && input ? lib.homeManagerConfiguration)
                      then input.packages.${system}.docs-json + "/share/doc/home-manager/options.json"
                      else let
                        modules =
                          lib.optionalAttrs (input ? "${type.full}Module") {
                            default = input."${type.full}Module";
                          }
                          // (lib.optionalAttrs (input ? "${type.full}Modules") (input."${type.full}Modules"))
                          // (lib.optionalAttrs (input ? modules.${type.full}) (input.modules.${type.full}));
                        namedModules = removeAttrs modules ["default"];
                      in
                        (mkModuleDoc {
                          inherit type;
                          source = input;
                          modules = builtins.attrValues (
                            if namedModules == {}
                            then modules
                            else namedModules
                          );
                        }).optionsJSON
                        + "/share/doc/nixos/options.json";
                  })
              )
              {}
              moduleTypes;
            input-json-docs = {};
          };
        }))
      non-referential-inputs;

    idr-generate-docs = pkgs.writeShellScriptBin "idr-generate-docs" ''
      set -e
      mkdir -p docs/generated
      temporary_directory=$(mktemp -d docs/.idr-generated.XXXXXX)
      trap 'rm -rf "$temporary_directory"' EXIT

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: doc: ''
          cp ${doc} "$temporary_directory/${name}-options.md"
        '')
        docs)}
      cp ${inputs-doc} "$temporary_directory/inputs.md"

      echo "# Lib" > "$temporary_directory/lib.md"

      ${lib.concatStringsSep "\n" (builtins.map (
          l: ''
            ${cfg.nixdoc.package}/bin/nixdoc \
              --file ${lib.escapeShellArg l.path} \
              --description ${lib.escapeShellArg l.description} \
              --category ${lib.escapeShellArg l.category} \
              --anchor-prefix ${lib.escapeShellArg l.anchorPrefix} \
              --prefix ${lib.escapeShellArg l.prefix} \
              >> "$temporary_directory/lib.md"
          ''
        )
        cfg.nixdoc.libs)}

      mv -ft docs/generated "$temporary_directory/"*
    '';
  in {
    options.idr.documentation = with lib; {
      enable = mkOption {
        description = ''
          Enable documentation helpers.
        '';
        type = types.bool;
        default = true;
      };
      assets = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["docs/assets" "LICENSE"];
        description = ''
          Additional project-relative files or directories to include in documentation
          builds. Markdown files and book configuration are included automatically.
        '';
      };
      nixdoc = {
        package = mkOption {
          description = ''
            nixdoc package
          '';
          type = types.package;
          internal = true;
          defaultText = "nixdoc package";
          default = pkgs.nixdoc;
        };
        libs = mkOption {
          description = ''
            Creates documentation to provided list of nix files using [nixdoc](https://github.com/nix-community/nixdoc).

            Documentation will be generated at ./docs/generated/lib.md.
          '';
          type = types.listOf (types.submodule {
            options = {
              path = mkOption {
                description = ''
                  Path to the Nix file. Relative Nix paths resolve from the file
                  containing the declaration.
                '';
                type = types.path;
              };
              prefix = mkOption {
                description = ''
                  Prefix for the category (e.g. 'lib' or 'utils')
                '';
                type = types.str;
                default = "";
              };
              anchorPrefix = mkOption {
                description = ''
                  Prefix for anchor links
                '';
                type = types.str;
                default = "";
              };
              category = mkOption {
                description = ''
                  Name of the function category (e.g. 'strings', 'attrsets')
                '';
                type = types.str;
                default = "";
              };
              description = mkOption {
                description = ''
                  Description of the function category
                '';
                type = types.str;
                default = "";
              };
            };
          });
          default = [];
        };
      };
      specialArgs = {
        nixos = mkOption {
          description = ''
            Attributes which will be passed to evalModules on generating nixos module options documentation.
          '';
          type = types.attrsOf types.unspecified;
          default = {};
        };
        flake = mkOption {
          description = ''
            Attributes which will be passed to evalModules on generating flake module options documentation.
          '';
          type = types.attrsOf types.unspecified;
          default = {};
        };
        homeManager = mkOption {
          description = ''
            Attributes which will be passed to evalModules on generating home manager module options documentation.
          '';
          type = types.attrsOf types.unspecified;
          default = {
            config = {
              sops = {
                defaultSopsFormat = "yaml";
                defaultSopsKey = "";
                defaultSymlinkPath = "";
              };
              xdg = {
                configHome = "";
              };
            };
          };
        };
        devshell = mkOption {
          description = ''
            Attributes which will be passed to evalModules on generating devshell module options documentation.
          '';
          type = types.attrsOf types.unspecified;
          default = {};
        };
        darwin = mkOption {
          description = ''
            Arguments passed to evalModules when generating Darwin module option documentation.
          '';
          type = types.attrsOf types.unspecified;
          default = {};
        };
        service = mkOption {
          description = ''
            Arguments passed to evalModules when generating service module option documentation.
          '';
          type = types.attrsOf types.unspecified;
          default = {};
        };
        generic = mkOption {
          description = ''
            Attributes which will be passed to evalModules on generating nixos generic options documentation.
          '';
          type = types.attrsOf types.unspecified;
          default = {};
        };
      };
      mk-docs = mkOption {
        description = ''
          Package that builds the project documentation using mdBook.
        '';
        type = types.package;
        internal = true;
        defaultText = "mk-docs package";
        default = pkgs.callPackage ./mk-docs.nix {
          stdenv = pkgs.stdenvNoCC;
          src = self;
          inherit (cfg) assets;
          inherit idr-generate-docs json-docs input-json-docs;
        };
      };
    };

    config = lib.mkIf cfg.enable {
      devshells.default = flake-parts-lib.importApply ./devshell.nix {
        inherit (cfg) mk-docs;
        inherit idr-generate-docs;
      };

      packages = {
        idr-mk-docs =
          cfg.mk-docs.overrideAttrs
          (prevAttrs: {
            passthru = prevAttrs.passthru // perTypeDocs;
          });
        idr-open-docs = pkgs.writeShellScriptBin "idr-open-docs" ''
          # Finds first executable browser in a colon-separated list.
          # (see how xdg-open defines BROWSER)
          browser="$(
            IFS=: ; for b in $BROWSER; do
              [ -x "$(type -P "$b" || true)" ] && echo "$b" && break
            done
          )"
          if [ -z "$browser" ]; then
            browser="$(type -P ${
            if pkgs.stdenv.hostPlatform.isDarwin
            then "open"
            else "xdg-open"
          } || true)"
            if [ ! -x "$browser" ]; then
              browser="${pkgs.w3m-nographics}/bin/w3m"
            fi
          fi
          exec "$browser" ''${BROWSER_ARGS:-} ${config.packages.idr-mk-docs}/html/index.html
        '';
      };
    };
  });
}

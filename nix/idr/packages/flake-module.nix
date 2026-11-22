_: {
  lib,
  flake-parts-lib,
  ...
}: {
  options.perSystem = flake-parts-lib.mkPerSystemOption ({
    config,
    pkgs,
    ...
  }: let
    declared = config.idr.packages;
  in {
    options.idr.packages = lib.mkOption {
      description = ''
        Packages in the nixpkgs format, exported as `packages.<system>.<name>` on
        the systems they support and updated by `idr-update-packages`.
      '';
      default = {};
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          package = lib.mkOption {
            type = lib.types.package;
            description = "The package, usually `pkgs.callPackage ./package.nix {}`.";
          };
          update = lib.mkOption {
            type = lib.types.path;
            default = pkgs.writeShellScript "update-${name}" ''
              exec ${lib.getExe pkgs.nix-update} --flake ${lib.escapeShellArg name}
            '';
            defaultText = lib.literalMD "a script running `nix-update --flake <name>`";
            description = ''
              Executable that updates `package` for every system. `idr-update-packages`
              runs it once, from the project root, as declared for the development
              shell's system.
            '';
          };
        };
      }));
    };

    config = lib.mkIf (declared != {}) {
      packages =
        lib.filterAttrs (_: lib.meta.availableOn pkgs.stdenv.hostPlatform)
        (lib.mapAttrs (_: declaration: declaration.package) declared);
      devshells.default.commands = [
        {
          name = "idr-update-packages";
          package = import ./command.nix {
            inherit pkgs;
            packages =
              lib.mapAttrs (name: declaration: {
                update = "${declaration.update}";
                build = config.packages ? ${name};
              })
              declared;
          };
          help = "Update declared packages";
        }
      ];
    };
  });
}

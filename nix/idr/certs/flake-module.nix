top: {
  lib,
  self,
  flake-parts-lib,
  ...
}: {
  config.flake.modules.nixos.certs = lib.modules.importApply ./nixos-module.nix top;

  options.perSystem = flake-parts-lib.mkPerSystemOption ({
    config,
    pkgs,
    ...
  }: {
    options.idr.certs = lib.mkOption {
      description = "Certificates issued outside the target machines and stored in SOPS.";
      default = {};
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          sopsFile = lib.mkOption {
            type = lib.types.path;
            description = "Project SOPS JSON or YAML file receiving the certificate and private key.";
          };
          domains = lib.mkOption {
            type = lib.types.nonEmptyListOf lib.types.str;
            description = "Certificate domain names, including any wildcard names.";
          };
          email = lib.mkOption {
            type = lib.types.str;
            description = "ACME account contact email.";
          };
          legoFlags = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Additional Lego flags, including the challenge provider.";
          };
          envRename = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Environment variables to populate from differently named variables for this certificate.";
          };
        };
      });
    };

    config = {
      packages.idr-update-certs = import ./package.nix {
        inherit pkgs;
        certs = lib.mapAttrs (name: cert: let
          path = toString cert.sopsFile;
        in
          cert
          // {
            sopsFile =
              if lib.hasPrefix "${self}/" path
              then lib.removePrefix "${self}/" path
              else throw "Certificate ${name}: sopsFile must belong to the current project.";
          })
        config.idr.certs;
      };
      devshells.default.commands = [
        {
          name = "idr-update-certs";
          package = config.packages.idr-update-certs;
          help = "Issue due certificates and save them in SOPS";
        }
      ];
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        nixos-certificates = import ./checks/certificates.nix {
          inherit pkgs;
          inherit (top) inputs self;
        };
      };
    };
  });
}

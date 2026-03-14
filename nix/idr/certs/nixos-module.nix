top: {
  config,
  lib,
  ...
}: let
  sources = config.idr.certs-source;
  fields = {
    cert = "cert";
    certKey = "cert_key";
    certPem = "cert_pem";
  };
in {
  options.idr = {
    certs-source = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = "SOPS files containing certificates issued by idr-update-certs, indexed by certificate name.";
    };
    certs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = lib.mapAttrs (_: _:
          lib.mkOption {
            type = top.idr-lib.types.secret;
            description = "Runtime certificate material and its access and reload metadata.";
          })
        fields;
      });
      readOnly = true;
      default = lib.mapAttrs (name: _: lib.mapAttrs (_: field: config.idr.secrets."${name}_${field}") fields) sources;
      description = "Certificate chains, private keys, and combined PEM files resolved from idr.certs-source.";
    };
  };

  config = lib.mkIf (sources != {}) {
    idr.secrets-source = lib.concatMapAttrs (name: sopsFile:
      lib.mapAttrs' (_: field: lib.nameValuePair "${name}_${field}" {inherit sopsFile;}) fields)
    sources;
    sops.secrets = lib.concatMapAttrs (name: sopsFile:
      lib.mapAttrs' (_: field:
        lib.nameValuePair "${name}_${field}" {
          format =
            if lib.hasSuffix ".json" (toString sopsFile)
            then "json"
            else "yaml";
        })
      fields)
    sources;
  };
}

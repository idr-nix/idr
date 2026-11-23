top: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.idr.ingress;
  meshId = config.idr.mesh.id;
in {
  _class = "service";
  key = toString ./ingress-backend.nix;
  imports = [top.self.modules.service.mesh];

  options.idr.ingress = {
    id = mkOption {
      type = types.strMatching "[0-9a-f]{12}";
      example = "b2b2b2b2b2b2";
      description = "Mesh ID of the ingress that serves this service.";
    };
    psk = mkOption {
      type = top.idr-lib.types.secretSource;
      description = ''
        Secret source of the PSK that this service and the ingress share. The
        ingress's machine reads it too, so it cannot be a reference.
      '';
    };
    certificates = mkOption {
      type = types.attrsOf types.path;
      default = {};
      example = lib.literalExpression ''{"tls-<role id>" = ./certs.enc.json;}'';
      description = ''
        Certificates for this service's domains, chosen by the role: names of
        certificates issued by `idr-update-certs`, and their JSON SOPS files, as
        in `idr.certs-source`. The ingress's machine reads them.
      '';
    };
    listeners = mkOption {
      type = types.listOf types.str;
      default = ["https" "http3"];
      description = ''
        The ingress's listeners that serve this service, which the ingress must
        have. Each sends the certificates' domains to its filter chains of the
        same names.
      '';
    };
    routes = mkOption {
      type = types.str;
      default = "https";
      description = ''
        Which of the ingress's route tables serves this service, chosen by the
        role. The service's `envoy` puts its virtual hosts there.
      '';
    };
    envoy = mkOption {
      type = types.deferredModule;
      default = {};
      description = ''
        Envoy configuration for the ingress, in the format of its `idr.envoy`,
        typically a virtual host in the `routes` table and a cluster. It cannot
        contain secret references: they are paths on this service's machine.
      '';
    };
    module = mkOption {
      type = types.deferredModule;
      readOnly = true;
      description = ''
        Module for the ingress service to import: it makes this service a peer
        of the ingress, and adds `envoy` and the certificates to the ingress's
        configuration.
      '';
    };
  };

  config = {
    idr.mesh.peers.${cfg.id}.psk = cfg.psk;
    idr.ingress.module = {config, ...}: {
      imports = [top.self.modules.service.envoy];
      idr.mesh.peers.${meshId}.psk = cfg.psk;
      # The certificate and its key in one file, so that a renewal is one update.
      idr.secrets-source =
        lib.mapAttrs (name: sopsFile: {
          inherit sopsFile;
          key = "${name}_cert_pem";
        })
        cfg.certificates;
      # A function, as an attribute set would only define configuration.
      idr.envoy = _: {
        imports = [
          cfg.envoy
          {
            resources = {
              secrets =
                lib.mapAttrsToList (name: _: {
                  inherit name;
                  tls_certificate = {
                    certificate_chain = config.idr.secrets.${name};
                    private_key = config.idr.secrets.${name};
                  };
                })
                cfg.certificates;
              listeners = lib.optionals (cfg.certificates != {}) (map (listener: {
                  name = listener;
                  filter_chain_matcher.matcher_tree.custom_match.typed_config.domain_matchers =
                    lib.mapAttrsToList (name: sopsFile: {
                      domains = top.idr-lib.certificateDomains name sopsFile;
                      on_match.action = {
                        inherit name;
                        typed_config = {
                          "@type" = "type.googleapis.com/google.protobuf.StringValue";
                          value = name;
                        };
                      };
                    })
                    cfg.certificates;
                })
                cfg.listeners);
            };
          }
        ];
      };
    };
  };
}

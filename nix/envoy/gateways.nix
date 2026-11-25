top: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  ingress = config.idr.ingress;
  egress = config.idr.egress;
  meshId = config.idr.mesh.id;
  meshIdType = types.nullOr (types.strMatching "[0-9a-f]{12}");
  # Where this service's instances connect from: its cluster's prefix and its
  # ID. WireGuard and the mesh links accept no other source from them.
  sources = {
    address_prefix = "${config.idr.mesh.ipv6Prefix}:${lib.concatMapStringsSep ":" (i: builtins.substring (i * 4) 4 meshId) [0 1 2]}::";
    prefix_len = 96;
  };
  secretsOption = gateway:
    mkOption {
      type = types.attrsOf top.idr-lib.types.secretSource;
      default = {};
      example = lib.literalExpression ''{openai-key = {sopsFile = ./openai.enc.json; key = "key";};}'';
      description = ''
        Secret sources that the ${gateway}'s machine reads, such as an API key.
        Each becomes a generic secret of the same name in the ${gateway}'s
        `resources.secrets`, which `envoy` refers to by name.
      '';
    };
  # The secrets, read on the gateway's machine, as Envoy's generic secrets.
  gatewaySecrets = secrets: {config, ...}: {
    idr.secrets-source = secrets;
    idr.envoy = _: {
      resources.secrets =
        lib.mapAttrsToList (name: _: {
          inherit name;
          generic_secret.secret = config.idr.secrets.${name};
        })
        secrets;
    };
  };
in {
  _class = "service";
  key = toString ./gateways.nix;
  imports = [top.self.modules.service.mesh];

  options.idr.ingress = {
    id = mkOption {
      type = meshIdType;
      default = null;
      example = "b2b2b2b2b2b2";
      description = "Mesh ID of the ingress that serves this service, if any.";
    };
    psk = mkOption {
      type = top.idr-lib.types.secretSource;
      description = ''
        Secret source of the PSK that this service and the ingress share. The
        ingress's machine reads it too, so it cannot be a reference.
      '';
    };
    secrets = secretsOption "ingress";
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
        typically a virtual host in the `routes` table and a cluster. It refers
        to `secrets` by name, and cannot contain secret references: they are
        paths on this service's machine.
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

  options.idr.egress = {
    id = mkOption {
      type = meshIdType;
      default = null;
      example = "c3c3c3c3c3c3";
      description = "Mesh ID of the egress that this service's requests to other domains go through, if any.";
    };
    psk = mkOption {
      type = top.idr-lib.types.secretSource;
      description = ''
        Secret source of the PSK that this service and the egress share. The
        egress's machine reads it too, so it cannot be a reference.
      '';
    };
    secrets = secretsOption "egress";
    domains = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["api.openai.com"];
      description = ''
        Domains that this service resolves to the egress, as in the mesh's
        peer `names`.
      '';
    };
    listeners = mkOption {
      type = types.listOf types.str;
      default = ["http"];
      description = ''
        The egress's listeners that this service connects to, which the egress
        must have. Each sends this service's connections, and only those, to
        its filter chain named after this service's mesh ID.
      '';
    };
    envoy = mkOption {
      type = types.deferredModule;
      default = {};
      description = ''
        Envoy configuration for the egress, in the format of its `idr.envoy`:
        this service's filter chain in each of `listeners`, named after its
        mesh ID, and the route tables and clusters that they use. It refers to
        `secrets` by name, and cannot contain secret references: they are paths
        on this service's machine.
      '';
    };
    module = mkOption {
      type = types.deferredModule;
      readOnly = true;
      description = ''
        Module for the egress service to import: it makes this service a peer
        of the egress, adds `envoy` to the egress's configuration, and sends
        this service's connections to its filter chains.
      '';
    };
  };

  config = {
    idr.mesh.peers = lib.mkMerge [
      (lib.mkIf (ingress.id != null) {${ingress.id}.psk = ingress.psk;})
      (lib.mkIf (egress.id != null) {
        ${egress.id} = {
          inherit (egress) psk;
          names = egress.domains;
        };
      })
    ];

    idr.ingress.module = {config, ...}: {
      imports = [top.self.modules.service.envoy (gatewaySecrets ingress.secrets)];
      idr.mesh.peers.${meshId}.psk = ingress.psk;
      # The certificate and its key in one file, so that a renewal is one update.
      idr.secrets-source =
        lib.mapAttrs (name: sopsFile: {
          inherit sopsFile;
          key = "${name}_cert_pem";
        })
        ingress.certificates;
      # A function, as an attribute set would only define configuration.
      idr.envoy = _: {
        imports = [
          ingress.envoy
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
                ingress.certificates;
              listeners = lib.optionals (ingress.certificates != {}) (map (listener: {
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
                    ingress.certificates;
                })
                ingress.listeners);
            };
          }
        ];
      };
    };

    idr.egress.module = {
      imports = [top.self.modules.service.envoy (gatewaySecrets egress.secrets)];
      idr.mesh.peers.${meshId}.psk = egress.psk;
      idr.envoy = _: {
        imports = [
          egress.envoy
          {
            # The connection's source picks the filter chain of the service
            # it comes from. Connections from elsewhere match no chain and
            # are closed.
            resources.listeners =
              map (listener: {
                name = listener;
                filter_chain_matcher.matcher_tree = {
                  input = {
                    name = "source-ip";
                    typed_config."@type" = "type.googleapis.com/envoy.extensions.matching.common_inputs.network.v3.SourceIPInput";
                  };
                  custom_match = {
                    name = "sources";
                    typed_config = {
                      "@type" = "type.googleapis.com/xds.type.matcher.v3.IPMatcher";
                      range_matchers = [
                        {
                          ranges = [sources];
                          on_match.action = {
                            name = meshId;
                            typed_config = {
                              "@type" = "type.googleapis.com/google.protobuf.StringValue";
                              value = meshId;
                            };
                          };
                        }
                      ];
                    };
                  };
                };
              })
              egress.listeners;
          }
        ];
      };
    };
  };
}

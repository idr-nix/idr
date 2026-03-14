top: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) types mkOption;
  cfg = config.idr.etcd;
  secret = top.idr-lib.types.secret;
  memberAddress = top.idr-lib.mkIPv6 "fdc1:ae6a:1782";
  package = mkOption {
    type = types.package;
    default = pkgs.etcd;
    defaultText = lib.literalExpression "pkgs.etcd";
    description = "etcd package to use.";
  };
  endpoints = mkOption {
    type = types.listOf (types.submodule {
      options = {
        domain = mkOption {
          type = types.str;
          description = "Client endpoint hostname, matching its TLS certificate.";
        };
        port = mkOption {
          type = types.port;
          default = 2379;
          description = "Client endpoint HTTPS port.";
        };
        ip = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional address to add to /etc/hosts for this endpoint.";
        };
      };
    });
    description = "Cluster client endpoints.";
  };
  caCert = mkOption {
    type = types.nullOr types.path;
    default = null;
    description = "Public CA certificate for cluster endpoints; null uses system trust.";
  };
in {
  options.idr.etcd = {
    enable = mkOption {
      type = types.bool;
      default =
        lib.any (instance: instance.enable) (lib.attrValues cfg.instances)
        || lib.any (proxy: proxy.enable) (lib.attrValues cfg.proxy)
        || cfg.rbac != [];
      defaultText = "Enabled when instances, proxies, or RBAC are configured.";
      description = "Whether to enable the configured etcd services.";
    };
    privateNetwork = {
      listenPort = mkOption {
        type = types.port;
        description = "Local WireGuard UDP port for communication between members.";
      };
      privKey = mkOption {
        type = secret;
        description = "This host's WireGuard private key.";
      };
      peers = mkOption {
        default = [];
        type = types.listOf (types.submodule {
          options = {
            endpoint = {
              address = mkOption {
                type = types.str;
                description = "Remote host's public IPv4 or IPv6 address.";
              };
              port = mkOption {
                type = types.port;
                description = "Remote host's WireGuard UDP port.";
              };
            };
            pubKey = mkOption {
              type = types.str;
              description = "Remote host's WireGuard public key.";
            };
            psk = mkOption {
              type = secret;
              description = "WireGuard preshared key for this pair of hosts.";
            };
            etcdPeers = mkOption {
              type = types.listOf types.str;
              description = "etcd member names hosted by this WireGuard peer.";
            };
          };
        });
        description = "WireGuard peers hosting other etcd members.";
      };
    };
    instances = mkOption {
      default = {};
      description = "Local etcd members, keyed by cluster-wide member name.";
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          inherit package;
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to run this member.";
          };
          dataDir = mkOption {
            type = types.path;
            description = "Existing persistent directory or mounted dataset for member data.";
          };
          cert = mkOption {
            type = secret;
            description = "Client endpoint TLS certificate chain in PEM format.";
          };
          certKey = mkOption {
            type = secret;
            description = "Client endpoint TLS private key in PEM format.";
          };
          clusterToken = mkOption {
            type = types.str;
            description = "Bootstrap token shared by all members of this cluster.";
          };
          publicHostname = mkOption {
            type = types.str;
            description = "Advertised client hostname, matching the TLS certificate.";
          };
          publicPort = mkOption {
            type = types.port;
            default = 2379;
            description = "HTTPS client listening port; local instances need distinct ports.";
          };
          allowedIPs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "IPv4 or IPv6 client addresses or CIDR ranges allowed through the firewall.";
          };
          address = mkOption {
            internal = true;
            readOnly = true;
            type = types.str;
            default = memberAddress name;
            defaultText = "IPv6 address derived from the member name.";
          };
          peers = mkOption {
            default = {};
            type = types.attrsOf (types.submodule ({name, ...}: {
              options.address = mkOption {
                internal = true;
                readOnly = true;
                type = types.str;
                default = memberAddress name;
                defaultText = "IPv6 address derived from the peer name.";
              };
            }));
            description = "Other members in the initial cluster, keyed by member name.";
          };
        };
      }));
    };
    proxy = mkOption {
      default = {};
      description = "Local gRPC proxies, exposed at <name>.etcd.internal:65535.";
      type = types.attrsOf (types.submodule {
        options = {
          inherit package endpoints caCert;
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to run this proxy.";
          };
          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Additional arguments to etcd grpc-proxy start.";
          };
        };
      });
    };
    rbac = mkOption {
      default = [];
      description = "Authoritative users and roles for each cluster; configure on one host per cluster.";
      type = types.listOf (types.submodule {
        options = {
          inherit package endpoints caCert;
          rootPassword = mkOption {
            type = secret;
            description = "Existing root password, also used to bootstrap authentication in a new cluster.";
          };
          roles = mkOption {
            default = {};
            type = types.attrsOf (types.submodule {
              options.permissions = mkOption {
                default = [];
                type = types.listOf (types.submodule {
                  options = {
                    target = mkOption {
                      type = types.oneOf [
                        types.str
                        (types.submodule {
                          options = {
                            from = mkOption {type = types.str;};
                            to = mkOption {type = types.str;};
                          };
                        })
                      ];
                      description = "Exact key, prefix, or a range with inclusive from and exclusive to.";
                    };
                    access = mkOption {
                      type = types.enum ["read" "write" "readwrite"];
                      default = "read";
                      description = "Allowed operations on this key or range.";
                    };
                    prefix = mkOption {
                      type = types.bool;
                      default = false;
                      description = "Interpret a string target as a key prefix.";
                    };
                  };
                });
                description = "Permissions granted to this role.";
              };
            });
            description = "Managed roles; the built-in root role is retained.";
          };
          users = mkOption {
            default = {};
            type = types.attrsOf (types.submodule {
              options = {
                password = mkOption {
                  type = secret;
                  description = "etcd user password.";
                };
                roles = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "Roles granted to this user.";
                };
              };
            });
            description = "Managed users; the administrator root account is retained.";
          };
        };
      });
    };
  };
}

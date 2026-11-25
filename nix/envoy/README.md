## Envoy

Run [Envoy](https://www.envoyproxy.io) as a [service mesh](../mesh/README.md)
workload. Import `modules.service.envoy` into a modular service and write its
configuration in Envoy's own formats:

- `idr.envoy.resources` holds `listeners`, `clusters`, `routes` (route tables)
  and `secrets`. Changes to them apply to the running Envoy.
- `idr.envoy` itself is Envoy's
  [bootstrap](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/bootstrap/v3/bootstrap.proto),
  for everything else, such as the admin interface or overload settings,
  besides idr's own `package` and `args`.

### Gateways

An application imports `modules.service.envoy-gateways` to be served by an
ingress, to reach other domains through an egress, or both: the role sets the
`id` of each gateway it uses.

| Option | Set by | Purpose |
|---|---|---|
| `idr.ingress.id` | role | The ingress's mesh ID. |
| `idr.ingress.psk` | role | Secret source of the PSK shared with the ingress. |
| `idr.ingress.certificates` | role | Certificates for the application's domains: names of certificates issued by [`idr-update-certs`](../certs/README.md), and their JSON SOPS files. Applications may share one. |
| `idr.ingress.listeners` | application | The ingress's listeners that serve the application, which the ingress must have; `["https" "http3"]` by default. |
| `idr.ingress.routes` | role | Which of the ingress's route tables serves the application; `https` by default. The application's `envoy` puts its virtual hosts there. |
| `idr.ingress.secrets` | role | Secret sources that the ingress's machine reads. Each is a generic secret of the same name in the ingress's `resources.secrets`. |
| `idr.ingress.envoy` | application | Configuration for the ingress, in `idr.envoy`'s format: typically a virtual host and a cluster. It refers to `secrets` by name, and cannot contain secret references. |
| `idr.ingress.module` | idr | Generated: the ingress imports it. It peers the two over the mesh, and adds `envoy` and the certificates to the ingress. |
| `idr.egress.id` | role | The egress's mesh ID. |
| `idr.egress.psk` | role | Secret source of the PSK shared with the egress. |
| `idr.egress.domains` | application | Domains that the application resolves to the egress. |
| `idr.egress.listeners` | application | The egress's listeners that the application connects to, which the egress must have; `["http"]` by default. |
| `idr.egress.secrets` | role | Secret sources that the egress's machine reads, such as an API key. Each is a generic secret of the same name in the egress's `resources.secrets`. |
| `idr.egress.envoy` | application | Configuration for the egress, in `idr.envoy`'s format: in each of `listeners`, a filter chain named after the application's mesh ID, and the route tables and clusters it uses. It refers to `secrets` by name, and cannot contain secret references. |
| `idr.egress.module` | idr | Generated: the egress imports it. It peers the two, adds `envoy` to the egress, and sends the application's connections, and only those, to its filter chains. |

The application calls the domains over plain HTTP, and the egress opens its own
connections, typically HTTPS, to the real hosts. The egress role gives Envoy
[internet access](../mesh/README.md#internet-access) and defines the listeners,
without publishing them.

Envoy's `credential_injector` filter can add an API key from `secrets` to the
application's requests.

### Example: an ingress for Vaultwarden

The example has three parts: a reusable Vaultwarden module that knows no
environment and no secrets, a role that deploys it to staging with its
certificate, and the ingress role, which owns the listeners.

The reusable module, in the Vaultwarden project's flake:

```nix
modules.service.vaultwarden = {config, lib, systemdPackage, ...}: let
  cfg = config.vaultwarden;
  environment = config.idr.secrets.vaultwarden-env;
  # Names are shared by everything on the ingress.
  name = "${config.idr.mesh.id}-vaultwarden";
in {
  imports = [inputs.idr.modules.service.envoy-gateways];

  options.vaultwarden = {
    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.nixpkgs.legacyPackages.${systemdPackage.stdenv.hostPlatform.system}.vaultwarden;
    };
    domains = lib.mkOption {type = lib.types.listOf lib.types.str;};
    port = lib.mkOption {type = lib.types.port; default = 8000;};
    adminToken = lib.mkOption {type = top.idr-lib.types.secretOrSource;};
  };

  config = {
    idr.secrets-source.vaultwarden-env.secrets.ADMIN_TOKEN = cfg.adminToken;

    process.argv = [(lib.getExe cfg.package)];
    systemd.service = {
      wants = [environment.restartTarget];
      after = [environment.restartTarget];
      partOf = [environment.restartTarget];
      environment = {
        DOMAIN = "https://${lib.head cfg.domains}";
        ROCKET_ADDRESS = "::";
        ROCKET_PORT = toString cfg.port;
        DATA_FOLDER = "/var/lib/vaultwarden";
        WEB_VAULT_FOLDER = "${cfg.package.webvault}/share/vaultwarden/vault";
      };
      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "vaultwarden";
        EnvironmentFile = environment.path;
      };
    };

    # For the ingress: a virtual host in its route table, and a cluster.
    idr.ingress.envoy.resources = {
      routes = [{
        name = config.idr.ingress.routes;
        virtual_hosts = [{
          inherit name;
          inherit (cfg) domains;
          # No timeout for long downloads and the notifications WebSocket.
          routes = [{match.prefix = "/"; route = {cluster = name; timeout = "0s";};}];
          request_headers_to_add = [{
            header = {key = "x-real-ip"; value = "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%";};
            append_action = "OVERWRITE_IF_EXISTS_OR_ADD";
          }];
        }];
      }];
      clusters = [{
        inherit name;
        type = "STRICT_DNS";
        dns_lookup_family = "V6_ONLY";
        load_assignment = {
          cluster_name = name;
          endpoints = [{
            lb_endpoints = [{
              endpoint.address.socket_address = {
                address = "${config.idr.mesh.id}.mesh";
                port_value = cfg.port;
              };
            }];
          }];
        };
      }];
    };
  };
};
```

The `stg-vaultwarden` role's `nixos-module.nix` sets the environment's domains,
IDs and secrets, and passes on the certificate that the role
[issues](../certs/README.md):

```nix
system.services.vaultwarden = {
  imports = [inputs.vaultwarden.modules.service.vaultwarden];
  idr.mesh.id = "a1a1a1a1a1a1";
  vaultwarden = {
    domains = ["vault.stg.example.com"];
    adminToken = {sopsFile = ./vaultwarden.enc.json; key = "admin_token";};
  };
  idr.ingress = {
    id = "b2b2b2b2b2b2";
    psk = {sopsFile = ./ingress-psk.enc.json; key = "psk";};
    certificates."tls-${(lib.importJSON ./meta.json).id}" = ./certs.enc.json;
  };
};
```

The certificate must cover the application's domains. The ingress's machine
becomes a recipient of the PSK and certificate files, so keep nothing else in
them.

The ingress role publishes port 443 for HTTPS (TCP) and HTTP/3 (UDP),
terminates TLS, and imports the module generated on a machine with the
`stg-vaultwarden` role. It also has a wildcard certificate of its own, for
applications that bring none:

```nix
system.services.ingress = {config, lib, ...}: let
  typed = type: {"@type" = "type.googleapis.com/envoy.extensions.${type}";};
  wildcard = "${config.idr.mesh.id}-stg";
  # The certificate and its key, in one file.
  pem = config.idr.secrets.stg-tls;
  certificates = lib.filter (secret: secret ? tls_certificate) config.idr.envoy.resources.secrets;
  tls = secret: {common_tls_context.tls_certificate_sds_secret_configs = [{inherit (secret) name;}];};
  # The requested domain (SNI) picks the filter chain of its certificate.
  # Applications add their certificates' domains to domain_matchers.
  byDomain.matcher_tree = {
    input = {
      name = "server-name";
      typed_config = typed "matching.common_inputs.network.v3.ServerNameInput";
    };
    custom_match = {
      name = "domains";
      typed_config = {
        "@type" = "type.googleapis.com/xds.type.matcher.v3.ServerNameMatcher";
        domain_matchers = [{
          domains = ["*.stg.example.com"];
          on_match.action = {
            name = wildcard;
            typed_config = {"@type" = "type.googleapis.com/google.protobuf.StringValue"; value = wildcard;};
          };
        }];
      };
    };
  };
  manager = options: {
    name = "envoy.filters.network.http_connection_manager";
    typed_config =
      typed "filters.network.http_connection_manager.v3.HttpConnectionManager"
      // {
        # Requests are internal by the client's address, not by an
        # X-Forwarded-For that it sends.
        use_remote_address = true;
        rds.route_config_name = "https";
        http_filters = [{
          name = "envoy.filters.http.router";
          typed_config = typed "filters.http.router.v3.Router";
        }];
      }
      // options;
  };
in {
  imports = [
    inputs.idr.modules.service.envoy
    self.nixosConfigurations.vault-stg-1.config.system.services.vaultwarden.idr.ingress.module
  ];
  idr.mesh = {
    id = "b2b2b2b2b2b2";
    publish = [{proto = "tcp"; port = 443;} {proto = "udp"; port = 443;}];
  };
  idr.secrets-source.stg-tls = {sopsFile = ./tls.enc.json; key = "stg_pem";};

  idr.envoy.resources = {
    # Each with a filter chain for each certificate, named after it.
    listeners = [
      {
        name = "https";
        address.socket_address = {address = "::"; port_value = 443; ipv4_compat = true;};
        listener_filters = [{
          name = "envoy.filters.listener.tls_inspector";
          typed_config = typed "filters.listener.tls_inspector.v3.TlsInspector";
        }];
        filter_chain_matcher = byDomain;
        filter_chains = map (secret: {
          inherit (secret) name;
          transport_socket = {
            name = "envoy.transport_sockets.tls";
            typed_config = typed "transport_sockets.tls.v3.DownstreamTlsContext" // tls secret;
          };
          filters = [(manager {
            stat_prefix = "https";
            upgrade_configs = [{upgrade_type = "websocket";}];
          })];
        }) certificates;
      }
      {
        name = "http3";
        address.socket_address = {protocol = "UDP"; address = "::"; port_value = 443; ipv4_compat = true;};
        udp_listener_config.quic_options = {};
        filter_chain_matcher = byDomain;
        filter_chains = map (secret: {
          inherit (secret) name;
          transport_socket = {
            name = "envoy.transport_sockets.quic";
            typed_config =
              typed "transport_sockets.quic.v3.QuicDownstreamTransport"
              // {downstream_tls_context = tls secret;};
          };
          filters = [(manager {
            stat_prefix = "http3";
            codec_type = "HTTP3";
            http3_protocol_options = {};
          })];
        }) certificates;
      }
    ];
    # Applications add virtual hosts. Alt-Svc tells clients about HTTP/3.
    routes = [{
      name = "https";
      response_headers_to_add = [{header = {key = "alt-svc"; value = "h3=\":443\"; ma=86400";};}];
    }];
    # Applications add their certificates.
    secrets = [{
      name = wildcard;
      tls_certificate = {certificate_chain = pem; private_key = pem;};
    }];
  };
};
```

The listeners refer to their route table and certificates by name: the route
table in `rds.route_config_name`, the certificates in
`tls_certificate_sds_secret_configs`. Define them under those names in
`resources.routes` and `resources.secrets`, and leave out `config_source` and
`sds_config`; the module adds them.

Each certificate is served for its domains, and the most specific one wins:
`vault.stg.example.com` gets Vaultwarden's certificate, other subdomains get the
wildcard. Clients that ask for another domain, or for none, get no certificate.

[Published ports](../mesh/README.md#published-ports) keep the client's address,
and Envoy passes it to Vaultwarden in `X-Real-IP`.

For an ingress open to the internet, see also Envoy's
[edge proxy best practices](https://www.envoyproxy.io/docs/envoy/latest/configuration/best_practices/edge),
such as connection limits and timeouts.

### Merging

Every module of an Envoy service writes into the same `idr.envoy`:

- In a list where every element, from every module, has a `name`, elements
  with the same name merge. This is how Vaultwarden's virtual host joins the
  ingress's `https` route table.
- Other lists concatenate, keeping one of equal elements. Lists of matchers,
  such as a route's `headers` or `query_parameters`, always do, although their
  elements have names.
- Different values for one field, such as a listener's port, fail evaluation.
  The usual `lib.mkDefault`, `lib.mkForce` and `lib.mkIf` work, also on list
  elements.

Names are shared by all modules of the service. Prefix a name with the mesh ID
of the service that declares it, as `<id>-vaultwarden` above, unless it should
merge.

### Secrets

Declare a secret in the service's
[`idr.secrets-source`](../secrets/README.md#modular-services) and put its
reference, `config.idr.secrets.<name>`, wherever Envoy accepts a data source,
as the ingress does with `stg-tls` above.

### Deployments

A deployment never stops Envoy:

- Changes to `resources`, and to the secrets they use, apply to the running
  Envoy. Route tables and secrets change without touching connections. A
  changed cluster drains only its own connections, and a listener whose filter
  chains changed only those chains; other listener changes drain the whole
  listener. A secret used in a cluster or listener changes it the same way.
- Other changes start a new Envoy that takes over the listeners: changes to the
  rest of `idr.envoy`, including `package` and `args`, and to the secrets it
  uses. The previous Envoy keeps its open connections for up to 15 minutes, then
  closes those that remain. Shorten that with Envoy's options:

```nix
idr.envoy.args = ["--drain-time-s" "60" "--parent-shutdown-time-s" "90"];
```

Each deployment validates the new configuration with the machine's secrets. An
invalid one fails the deployment, and Envoy keeps its previous configuration.

Changes to the service's systemd unit, such as its sandboxing, need
`systemctl restart <service>`.

top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    domain = "vault.example.test";
    statusDomain = "status.example.test";
    # Certificates as idr-update-certs saves them, told apart by subject:
    # first and rotated for Vaultwarden, status for the ingress itself.
    fixtures = ./fixtures;
    typed = type: {"@type" = "type.googleapis.com/envoy.extensions.${type}";};
    hosts = {
      alpha.address = "2001:db8:1::1";
      beta.address = "2001:db8:1::2";
    };
    ingressId = "444444444444";
    vaultwardenId = "555555555555";

    # A reusable Vaultwarden service module, as in the README: it knows no
    # environment, and generates the module that an ingress imports.
    vaultwarden = {
      config,
      lib,
      systemdPackage,
      ...
    }: let
      cfg = config.vaultwarden;
      environment = config.idr.secrets.vaultwarden-env;
      name = "${config.idr.mesh.id}-vaultwarden";
    in {
      imports = [top.self.modules.service.ingress-backend];

      options.vaultwarden = {
        package = lib.mkOption {
          type = lib.types.package;
          default = top.inputs.nixpkgs.legacyPackages.${systemdPackage.stdenv.hostPlatform.system}.vaultwarden;
          description = "Vaultwarden package to run.";
        };
        domains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = "Domains that Vaultwarden is served at; the first is its own address.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 8000;
          description = "Port Vaultwarden listens on in its mesh namespace.";
        };
        adminToken = lib.mkOption {
          type = top.idr-lib.types.secretOrSource;
          description = "Token for the admin page.";
        };
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
          routes = [
            {
              name = config.idr.ingress.routes;
              virtual_hosts = [
                {
                  inherit name;
                  inherit (cfg) domains;
                  routes = [
                    {
                      match.prefix = "/";
                      # No timeout for long downloads and the notifications WebSocket.
                      route = {
                        cluster = name;
                        timeout = "0s";
                      };
                    }
                  ];
                  request_headers_to_add = [
                    {
                      header = {
                        key = "x-real-ip";
                        value = "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%";
                      };
                      append_action = "OVERWRITE_IF_EXISTS_OR_ADD";
                    }
                  ];
                }
              ];
            }
          ];
          clusters = [
            {
              inherit name;
              type = "STRICT_DNS";
              dns_lookup_family = "V6_ONLY";
              load_assignment = {
                cluster_name = name;
                endpoints = [
                  {
                    lb_endpoints = [
                      {
                        endpoint.address.socket_address = {
                          address = "${config.idr.mesh.id}.mesh";
                          port_value = cfg.port;
                        };
                      }
                    ];
                  }
                ];
              };
            }
          ];
        };
      };
    };
  in {
    checks.envoy-ingress = pkgs.testers.runNixOSTest ({meshFixture, ...}: let
      psk = {exec = "printf %s ${meshFixture.psk}";};
    in {
      imports = [(lib.modules.importApply ../../mesh/checks/fixture.nix {inherit top;})];
      name = "envoy-ingress";

      nodes = lib.mkMerge [
        (lib.mapAttrs (name: host: {
            networking.interfaces.eth1.ipv6.addresses = [
              {
                inherit (host) address;
                prefixLength = 64;
              }
            ];
            networking.firewall.filterForward = true;
          })
          hosts)
        {
          # The ingress role: its listeners for HTTPS and HTTP/3, each with a
          # filter chain per certificate, the route table, and the module that
          # Vaultwarden's service generated.
          alpha = {nodes, ...}: {
            system.services.ingress = {
              config,
              lib,
              ...
            }: let
              certificates = lib.filter (secret: secret ? tls_certificate) config.idr.envoy.resources.secrets;
              tls = secret: {common_tls_context.tls_certificate_sds_secret_configs = [{inherit (secret) name;}];};
              # The requested domain (SNI) picks the filter chain of its
              # certificate. Applications add their domains to domain_matchers.
              byDomain.matcher_tree = {
                input = {
                  name = "server-name";
                  typed_config = typed "matching.common_inputs.network.v3.ServerNameInput";
                };
                custom_match = {
                  name = "domains";
                  typed_config."@type" = "type.googleapis.com/xds.type.matcher.v3.ServerNameMatcher";
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
                    http_filters = [
                      {
                        name = "envoy.filters.http.router";
                        typed_config = typed "filters.http.router.v3.Router";
                      }
                    ];
                  }
                  // options;
              };
            in {
              imports = [
                top.self.modules.service.envoy
                nodes.beta.system.services.vaultwarden.idr.ingress.module
              ];
              idr.mesh = {
                id = ingressId;
                publish = [
                  {
                    proto = "tcp";
                    port = 443;
                  }
                  {
                    proto = "udp";
                    port = 443;
                  }
                ];
              };
              idr.envoy.resources = {
                listeners = [
                  {
                    name = "https";
                    address.socket_address = {
                      address = "::";
                      port_value = 443;
                      ipv4_compat = true;
                    };
                    listener_filters = [
                      {
                        name = "envoy.filters.listener.tls_inspector";
                        typed_config = typed "filters.listener.tls_inspector.v3.TlsInspector";
                      }
                    ];
                    filter_chain_matcher = byDomain;
                    filter_chains =
                      map (secret: {
                        inherit (secret) name;
                        transport_socket = {
                          name = "envoy.transport_sockets.tls";
                          typed_config = typed "transport_sockets.tls.v3.DownstreamTlsContext" // tls secret;
                        };
                        filters = [
                          (manager {
                            stat_prefix = "https";
                            upgrade_configs = [{upgrade_type = "websocket";}];
                          })
                        ];
                      })
                      certificates;
                  }
                  {
                    name = "http3";
                    address.socket_address = {
                      protocol = "UDP";
                      address = "::";
                      port_value = 443;
                      ipv4_compat = true;
                    };
                    udp_listener_config.quic_options = {};
                    filter_chain_matcher = byDomain;
                    filter_chains =
                      map (secret: {
                        inherit (secret) name;
                        transport_socket = {
                          name = "envoy.transport_sockets.quic";
                          typed_config =
                            typed "transport_sockets.quic.v3.QuicDownstreamTransport"
                            // {downstream_tls_context = tls secret;};
                        };
                        filters = [
                          (manager {
                            stat_prefix = "http3";
                            codec_type = "HTTP3";
                            http3_protocol_options = {};
                          })
                        ];
                      })
                      certificates;
                  }
                ];
                # Applications add virtual hosts. Alt-Svc tells clients that
                # HTTP/3 is available.
                routes = [
                  {
                    name = "https";
                    response_headers_to_add = [
                      {
                        header = {
                          key = "alt-svc";
                          value = "h3=\":443\"; ma=86400";
                        };
                      }
                    ];
                  }
                ];
              };
              systemd.service.wantedBy = lib.mkOverride 900 [];
            };
            # Deployments: one adds a domain with its route and the ingress's
            # own certificate, one renews Vaultwarden's certificate, one
            # changes a bootstrap argument, one routes to a missing cluster
            # and renews the certificate too.
            specialisation = let
              # The role's file once idr-update-certs renews the certificate.
              renewal.system.services.ingress.idr.secrets-source.tls-vault.sopsFile =
                lib.mkForce (fixtures + "/vault-rotated.enc.json");
              status = action: {
                system.services.ingress.idr.envoy.resources.routes = [
                  {
                    name = "https";
                    virtual_hosts = [
                      {
                        name = "status";
                        domains = [statusDomain];
                        routes = [({match.prefix = "/";} // action)];
                      }
                    ];
                  }
                ];
              };
            in {
              updated.configuration = {
                imports = [
                  (status {
                    direct_response = {
                      status = 200;
                      body.inline_string = "updated";
                    };
                  })
                ];
                system.services.ingress = {config, ...}: let
                  sopsFile = fixtures + "/status.enc.json";
                in {
                  idr.secrets-source.tls-status = {
                    inherit sopsFile;
                    key = "tls-status_cert_pem";
                  };
                  idr.envoy.resources = {
                    secrets = [
                      {
                        name = "tls-status";
                        tls_certificate = {
                          certificate_chain = config.idr.secrets.tls-status;
                          private_key = config.idr.secrets.tls-status;
                        };
                      }
                    ];
                    listeners = map (name: {
                      inherit name;
                      filter_chain_matcher.matcher_tree.custom_match.typed_config.domain_matchers = [
                        {
                          domains = top.idr-lib.certificateDomains "tls-status" sopsFile;
                          on_match.action = {
                            name = "tls-status";
                            typed_config = {
                              "@type" = "type.googleapis.com/google.protobuf.StringValue";
                              value = "tls-status";
                            };
                          };
                        }
                      ];
                    }) ["https" "http3"];
                  };
                };
              };
              renewed.configuration = renewal;
              broken.configuration.imports = [(status {route.cluster = "missing";}) renewal];
              arguments.configuration.system.services.ingress.idr.envoy.args = ["--drain-time-s" "60"];
            };
          };
          # The Vaultwarden role: the environment and its secrets.
          beta = {
            environment.systemPackages = [pkgs.openssl];
            systemd.tmpfiles.rules = [
              "C /run/mesh-test-secrets/admin-token 0400 root root - ${pkgs.writeText "admin-token" "public-test-admin-token"}"
            ];
            system.services.vaultwarden = {
              imports = [vaultwarden];
              idr.mesh.id = vaultwardenId;
              vaultwarden = {
                domains = [domain];
                adminToken = meshFixture.secret "admin-token";
              };
              idr.ingress = {
                id = ingressId;
                inherit psk;
                certificates.tls-vault = fixtures + "/vault-first.enc.json";
              };
              systemd.service.wantedBy = lib.mkOverride 900 [];
            };
          };
        }
      ];

      testScript =
        meshFixture.script
        + ''
          setup_mesh()
          beta.succeed("systemctl start vaultwarden.service")
          alpha.succeed("systemctl start ingress.service")
          alpha.wait_for_unit("ingress.service")
          wait_registered(beta, "vaultwarden")
          wait_registered(alpha, "ingress")

          def get(address, path="/alive", host="${domain}", options="", http3=False):
              target = f"[{address}]" if ":" in address else address
              curl = "${lib.getExe' pkgs.curlHTTP3 "curl"} --http3-only" if http3 else "curl"
              return (
                  f"{curl} --noproxy '*' --fail --silent --show-error --max-time 4 --cacert /tmp/ca.pem "
                  + f"--resolve {host}:443:{target} {options} https://{host}{path}"
              )

          def invocation():
              return alpha.succeed("systemctl show ingress.service --property=InvocationID,MainPID").strip()

          def envoys():
              return set(alpha.succeed("pgrep --exact envoy").split())

          # The subject of the certificate that the ingress presents, if any.
          def subject(options="-servername ${domain}"):
              return beta.succeed(
                  f"openssl s_client -connect '[2001:db8:1::1]:443' {options} < /dev/null 2> /dev/null"
                  + " | openssl x509 -noout -subject 2> /dev/null || echo none"
              ).strip()

          # The same over HTTP/3, as curl reports it.
          def subject_http3():
              return beta.succeed(
                  get("2001:db8:1::1", options="--verbose", http3=True)
                  + " 2>&1 | grep --only-matching 'subject: CN=[a-z]*' | head -1 || true"
              ).strip()

          # Requests from beta every 100 ms while alpha changes; none may fail.
          def start_probe(name, http3=False):
              beta.succeed(
                  f"rm -f /tmp/{name}; (for _ in $(seq 150); do "
                  + get("2001:db8:1::1", http3=http3)
                  + f" > /dev/null 2>&1 || echo failed; sleep 0.1; done > /tmp/{name}; echo finished >> /tmp/{name})"
                  + " > /dev/null 2>&1 &"
              )

          def finish_probe(name):
              beta.wait_until_succeeds(f"grep -q finished /tmp/{name}", timeout=120)
              assert beta.succeed(f"cat /tmp/{name}").strip() == "finished", name

          # Failed admin logins that Vaultwarden logged from an address.
          def admin_failures(source):
              return int(beta.succeed(
                  f"(journalctl --unit=vaultwarden.service --output=cat --grep='Invalid admin token. IP: {source}$' || true) | wc -l"
              ))

          # One HTTPS connection that beta keeps open, sending a request on demand.
          def request_on_connection():
              beta.succeed(
                  "printf 'GET /alive HTTP/1.1\\r\\nHost: ${domain}\\r\\n\\r\\n' > /tmp/connection.in"
              )

          # Bodies end without a newline, so status lines can start mid-line.
          def responses_on_connection(count):
              beta.wait_until_succeeds(
                  f"test $(grep -o 'HTTP/1.1 200' /tmp/connection.out | wc -l) = {count}", timeout=30
              )

          beta.succeed("cp ${fixtures}/ca.pem /tmp/ca.pem")

          with subtest("resources go to watched files, and validation inlines them"):
              xds = "/etc/system-services/ingress/xds"
              listeners = json.loads(alpha.succeed(f"cat {xds}/lds.json"))["resources"]
              assert [listener["name"] for listener in listeners] == ["https", "http3"], listeners
              for listener in listeners:
                  assert [chain["name"] for chain in listener["filter_chains"]] == ["tls-vault"], listener
                  matchers = listener["filter_chain_matcher"]["matcher_tree"]["custom_match"]["typed_config"]["domain_matchers"]
                  assert [(m["domains"], m["on_match"]["action"]["name"]) for m in matchers] == [(["${domain}"], "tls-vault")], matchers
              manager = listeners[0]["filter_chains"][0]["filters"][0]["typed_config"]
              assert manager["rds"]["config_source"]["path_config_source"]["path"].startswith("/run/idr-envoy-ingress/xds/routes/")
              routes = json.loads(alpha.succeed(f"cat {xds}/routes/*.json"))["resources"][0]
              assert [host["name"] for host in routes["virtual_hosts"]] == ["${vaultwardenId}-vaultwarden"], routes
              inlined = json.loads(alpha.succeed("cat /etc/system-services/ingress/validate.json"))
              hosts = inlined["static_resources"]["listeners"][0]["filter_chains"][0]["filters"][0]["typed_config"]["route_config"]["virtual_hosts"]
              assert [host["name"] for host in hosts] == ["${vaultwardenId}-vaultwarden"], hosts
              assert "PRIVATE KEY" not in alpha.succeed(f"cat {xds}/secrets/*.json /etc/system-services/ingress/*.json")
              # The certificate and its key are one file.
              assert alpha.succeed("stat --format=%a /run/idr-envoy-ingress/secrets/*").split() == ["400"]

          with subtest("published HTTPS and HTTP/3 reach Vaultwarden over the mesh with the client's address"):
              for address in ["2001:db8:1::1", "192.168.1.1"]:
                  beta.wait_until_succeeds(get(address), timeout=90)
                  beta.wait_until_succeeds(get(address, http3=True), timeout=30)
              beta.succeed(get("2001:db8:1::1", path="/admin"))
              assert 'alt-svc: h3=":443"' in beta.succeed(get("2001:db8:1::1", options="--include")).lower()
              # Vaultwarden logs a failed admin login with the client's address,
              # also when the client claims another one.
              for address, source in [("2001:db8:1::1", "2001:db8:1::2"), ("192.168.1.1", "192.168.1.2")]:
                  for http3 in [False, True]:
                      before = admin_failures(source)
                      beta.fail(get(address, path="/admin", options="--data token=wrong --header 'X-Real-IP: 203.0.113.9'", http3=http3))
                      retry(lambda _: admin_failures(source) > before, timeout_seconds=30)
              beta.fail(get("2001:db8:1::1", host="${statusDomain}", path="/"))

          with subtest("a WebSocket stays open past Envoy's default route timeout"):
              # Vaultwarden's anonymous notification hub accepts any token.
              reply = beta.succeed(
                  "curl --noproxy '*' --silent --http1.1 --include --no-buffer --max-time 17 --cacert /tmp/ca.pem"
                  + " --resolve ${domain}:443:[2001:db8:1::1]"
                  + " --header 'Connection: Upgrade' --header 'Upgrade: websocket'"
                  + " --header 'Sec-WebSocket-Version: 13' --header 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='"
                  + " 'https://${domain}/notifications/anonymous-hub?Token=test' || echo \"exit=$?\""
              )
              assert "HTTP/1.1 101" in reply, reply
              # Still open when curl gave up after 17 seconds.
              assert reply.strip().endswith("exit=28"), reply

          with subtest("only a certificate's domains get a certificate"):
              assert subject() == "subject=CN=first", subject()
              for options in ["-servername other.example.test", "-servername ${statusDomain}", "-noservername"]:
                  assert subject(options) == "none", options
              beta.fail(get("2001:db8:1::1", host="other.example.test", http3=True))

          before = invocation()
          processes = envoys()
          beta.succeed(
              "mkfifo /tmp/connection.in; (sleep infinity 1<> /tmp/connection.in 2> /dev/null < /dev/null &)",
              "(openssl s_client -quiet -connect '[2001:db8:1::1]:443' -servername ${domain} -CAfile /tmp/ca.pem"
              + " < /tmp/connection.in > /tmp/connection.out 2>&1 &)",
          )
          request_on_connection()
          responses_on_connection(1)

          with subtest("a deployment of a domain and its certificate updates the running Envoy"):
              alpha.succeed("/run/booted-system/specialisation/updated/bin/switch-to-configuration test", timeout=180)
              for http3 in [False, True]:
                  reply = beta.wait_until_succeeds(get("2001:db8:1::1", host="${statusDomain}", path="/", http3=http3), timeout=60)
                  assert reply == "updated", reply
              assert subject("-servername ${statusDomain}") == "subject=CN=status"
              # The added filter chain leaves Vaultwarden's connection alone.
              request_on_connection()
              responses_on_connection(2)
              assert invocation() == before
              assert envoys() == processes

          with subtest("a renewed certificate updates the running Envoy"):
              assert subject() == "subject=CN=first", subject()
              # The renewed configuration has no status domain or certificate.
              alpha.succeed("/run/booted-system/specialisation/renewed/bin/switch-to-configuration test", timeout=180)
              retry(lambda _: subject() == "subject=CN=rotated", timeout_seconds=60)
              retry(lambda _: subject_http3() == "subject: CN=rotated", timeout_seconds=60)
              assert subject("-servername ${statusDomain}") == "none"
              request_on_connection()
              responses_on_connection(3)
              assert "connection: close" not in beta.succeed("cat /tmp/connection.out").lower()
              assert invocation() == before
              assert envoys() == processes

          with subtest("a changed argument starts a new Envoy that takes over"):
              start_probe("probe")
              start_probe("probe-http3", http3=True)
              alpha.succeed("/run/booted-system/specialisation/arguments/bin/switch-to-configuration test", timeout=180)
              retry(lambda _: envoys() - processes, timeout_seconds=60)
              finish_probe("probe")
              finish_probe("probe-http3")
              assert invocation() == before
              alpha.succeed("pgrep --full -- '--drain-time-s 60'")

          with subtest("an invalid configuration is refused and Envoy keeps serving"):
              current = envoys()
              alpha.fail("/run/booted-system/specialisation/broken/bin/switch-to-configuration test")
              # Reloads that the renewed secret started have finished too.
              alpha.wait_until_succeeds("! systemctl list-jobs | grep --quiet ingress.service", timeout=60)
              assert invocation() == before
              assert envoys() == current
              beta.succeed(get("2001:db8:1::1"), get("2001:db8:1::1", http3=True))
              # Nor did Envoy get the renewed certificate.
              assert subject() == "subject=CN=first", subject()
        '';
    });
  };
}

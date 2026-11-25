top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    domain = "api.example.test";
    typed = type: {"@type" = "type.googleapis.com/envoy.extensions.${type}";};
    hosts = {
      alpha.address = "2001:db8:1::1";
      beta.address = "2001:db8:1::2";
    };
    egressId = "666666666666";
    # A CA and the stand-in API's certificate, made for this test only.
    pki = pkgs.runCommand "envoy-egress-pki" {nativeBuildInputs = [pkgs.openssl];} ''
      mkdir $out
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj /CN=envoy-egress-test-ca -keyout ca.key -out $out/ca.pem
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -subj /CN=${domain} -keyout $out/api.key -out api.csr
      printf 'subjectAltName=DNS:${domain}\n' > extensions
      openssl x509 -req -in api.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial -days 3650 \
        -extfile extensions -out $out/api.pem
    '';
    # The API over TLS, checked against the test CA.
    api = {
      name = "api";
      type = "STATIC";
      load_assignment = {
        cluster_name = "api";
        endpoints = [
          {
            lb_endpoints = [
              {
                endpoint.address.socket_address = {
                  address = hosts.alpha.address;
                  port_value = 443;
                };
              }
            ];
          }
        ];
      };
      transport_socket = {
        name = "envoy.transport_sockets.tls";
        typed_config =
          typed "transport_sockets.tls.v3.UpstreamTlsContext"
          // {
            sni = domain;
            common_tls_context.validation_context = {
              trusted_ca.filename = "${pki}/ca.pem";
              match_typed_subject_alt_names = [
                {
                  san_type = "DNS";
                  matcher.exact = domain;
                }
              ];
            };
          };
      };
    };
    idle = {
      process.argv = [(lib.getExe' pkgs.coreutils "sleep") "infinity"];
      systemd.service = {
        wantedBy = lib.mkOverride 900 [];
        serviceConfig.DynamicUser = true;
      };
    };
  in {
    checks.envoy-egress = pkgs.testers.runNixOSTest ({meshFixture, ...}: let
      router = {
        name = "envoy.filters.http.router";
        typed_config = typed "filters.http.router.v3.Router";
      };
      # An application that may call one path of the API through the egress,
      # which can add the application's key to its requests.
      client = {
        path,
        key ? null,
      }: {config, ...}: let
        id = config.idr.mesh.id;
      in {
        imports = [top.self.modules.service.envoy-gateways idle];
        idr.egress = {
          id = egressId;
          psk.exec = "printf %s ${meshFixture.psk}";
          domains = [domain];
          secrets = lib.optionalAttrs (key != null) {"${id}-key".exec = "printf %s '${key}'";};
          envoy.resources = {
            listeners = [
              {
                name = "http";
                filter_chains = [
                  {
                    name = id;
                    filters = [
                      {
                        name = "envoy.filters.network.http_connection_manager";
                        typed_config =
                          typed "filters.network.http_connection_manager.v3.HttpConnectionManager"
                          // {
                            stat_prefix = id;
                            rds.route_config_name = id;
                            http_filters =
                              lib.optional (key != null) {
                                name = "envoy.filters.http.credential_injector";
                                typed_config =
                                  typed "filters.http.credential_injector.v3.CredentialInjector"
                                  // {
                                    overwrite = true;
                                    credential = {
                                      name = "envoy.http.injected_credentials.generic";
                                      typed_config = typed "http.injected_credentials.generic.v3.Generic" // {credential.name = "${id}-key";};
                                    };
                                  };
                              }
                              ++ [router];
                          };
                      }
                    ];
                  }
                ];
              }
            ];
            routes = [
              {
                name = id;
                virtual_hosts = [
                  {
                    name = "api";
                    domains = [domain];
                    routes = [
                      {
                        match.prefix = path;
                        route.cluster = "api";
                      }
                    ];
                  }
                ];
              }
            ];
            clusters = [api];
          };
        };
      };
    in {
      imports = [(lib.modules.importApply ../../mesh/checks/fixture.nix {inherit top;})];
      name = "envoy-egress";

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
          # Two applications that share the egress for different paths, and a
          # peer of the egress without a filter chain there. The stand-in API
          # runs outside the mesh.
          alpha = {
            system.services = {
              speech = {
                imports = [
                  (client {
                    path = "/v1/audio/speech";
                    key = "Bearer speech-key";
                  })
                ];
                idr.mesh.id = "777777777777";
              };
              chat = {
                imports = [(client {path = "/v1/chat";})];
                idr.mesh.id = "888888888888";
              };
              outsider = {
                imports = [top.self.modules.service.mesh idle];
                idr.mesh = {
                  id = "999999999999";
                  peers.${egressId}.psk = meshFixture.secret "psk";
                };
              };
            };
            networking.firewall.allowedTCPPorts = [443];
            services.nginx = {
              enable = true;
              virtualHosts.${domain} = {
                onlySSL = true;
                listen = [
                  {
                    addr = "[::]";
                    port = 443;
                    ssl = true;
                  }
                ];
                sslCertificate = "${pki}/api.pem";
                sslCertificateKey = "${pki}/api.key";
                locations = {
                  # Each answers with the credential it received.
                  "/v1/audio/speech".return = "200 \"speech:$http_authorization\"";
                  "/v1/chat".return = "200 \"chat:$http_authorization\"";
                };
              };
            };
          };
          # The egress role: its listener, and the applications' modules.
          beta = {nodes, ...}: {
            system.services.egress = {
              imports = [
                top.self.modules.service.envoy
                nodes.alpha.system.services.speech.idr.egress.module
                nodes.alpha.system.services.chat.idr.egress.module
              ];
              idr.mesh = {
                id = egressId;
                peers."999999999999".psk = meshFixture.secret "psk";
                internet = {
                  enable = true;
                  allow = [
                    {
                      proto = "tcp";
                      port = 443;
                      destinations = [hosts.alpha.address];
                    }
                  ];
                };
              };
              idr.envoy.resources.listeners = [
                {
                  name = "http";
                  address.socket_address = {
                    address = "::";
                    port_value = 80;
                  };
                }
              ];
              systemd.service.wantedBy = lib.mkOverride 900 [];
            };
            # The API's address is fixed in the cluster; these resolve nothing.
            idr.mesh.internet.nameservers = [hosts.alpha.address];
          };
        }
      ];

      testScript = ''
        ${meshFixture.script}
        domain = "${domain}"

        def call(service, path, host=domain, extra=""):
            return inside(
                f"curl --noproxy '*' --silent --show-error --connect-timeout 2 --max-time 4 {extra} http://{host}{path}",
                service,
            )

        def status(service, path):
            return call(service, path, extra="--output /dev/null --write-out '%{http_code}'")

        setup_mesh()
        alpha.succeed("systemctl start speech.service chat.service outsider.service")
        beta.succeed("systemctl start egress.service")
        for service in ["speech", "chat", "outsider"]:
            wait_registered(alpha, service)
        wait_registered(beta, "egress")

        with subtest("each application reaches only its own routes, over TLS"):
            # The egress adds speech's key, also over one that speech sends.
            for service, path, extra, body in [
                ("speech", "/v1/audio/speech", "", "speech:Bearer speech-key"),
                ("speech", "/v1/audio/speech", "--header 'Authorization: Bearer forged'", "speech:Bearer speech-key"),
                ("chat", "/v1/chat", "", "chat:"),
            ]:
                reply = alpha.wait_until_succeeds(call(service, path, extra=f"--fail {extra}"), timeout=60)
                assert reply.strip() == body, (service, reply)
            for service, path in [("speech", "/v1/chat"), ("chat", "/v1/audio/speech")]:
                code = alpha.succeed(status(service, path)).strip()
                assert code == "404", (service, path, code)

        with subtest("a peer without a filter chain gets nothing"):
            alpha.fail(inside(f"getent ahostsv6 {domain}", "outsider"))
            # The egress accepts the connection, which no filter chain takes.
            alpha.wait_until_succeeds(
                "if " + call("outsider", "/v1/chat", host="${egressId}.mesh", extra=f"--header 'Host: {domain}'")
                + "; then false; else test $? -eq 52; fi",
                timeout=60,
            )
      '';
    });
  };
}

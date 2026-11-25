top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    otherPrefix = "fd7a:3e19:c204";
  in {
    checks.mesh-link = pkgs.testers.runNixOSTest ({
      config,
      meshFixture,
      ...
    }: let
      inherit (meshFixture) secret;
      psk = {psk = secret "psk";};
      # A second cluster in the same etcd, with a user of its own on each
      # machine.
      otherRbac = let
        derived = top.idr-lib.meshRbac "other" (lib.mapAttrs (_: machine: {config = machine;}) config.nodes);
      in
        derived // {users = lib.mapAttrs (_: user: user // {password = secret "etcd-password-other";}) derived.users;};
      service = {
        id,
        body,
        peers,
      }: {
        imports = [
          (meshFixture.mkService {
            inherit id body;
            peers = [];
          })
        ];
        idr.mesh = {
          etcd = "other";
          inherit peers;
        };
      };
    in {
      imports = [
        (lib.modules.importApply ./fixture.nix {inherit top;})
      ];
      name = "mesh-link";

      defaults = {
        systemd.tmpfiles.rules = [
          "C /run/mesh-test-secrets/etcd-password-other 0440 root root - ${pkgs.writeText "mesh-test-etcd-password" "public-test-other"}"
        ];
        idr.mesh = {
          defaultEtcd = "main";
          etcd.other = {
            ipv6Prefix = otherPrefix;
            endpoint = "http://main.etcd.internal:1023";
            password = secret "etcd-password-other";
            inherit (meshFixture) leaseTTLSeconds;
          };
        };
      };

      nodes = {
        # app, in the default cluster, is linked to gateway and relay, in the
        # other, on alpha. It reaches edge through gateway.
        alpha = {
          idr.mesh.etcd.other.username = "mesh-alpha-other";
          idr.etcd.clusters.main.rbac = otherRbac;
          system.services = {
            app.idr.mesh.peers = {
              "666666666666" = {
                etcd = "other";
                names = ["gateway.example.test"];
                routes = ["777777777777"];
              };
              "888888888888".etcd = "other";
            };
            gateway = service {
              id = "666666666666";
              body = "gateway";
              peers = {
                "222222222222" = {
                  etcd = "main";
                  names = ["app.example.test"];
                  routes = ["777777777777"];
                };
                "777777777777" = psk;
              };
            };
            relay = service {
              id = "888888888888";
              body = "relay";
              peers."222222222222".etcd = "main";
            };
          };
          specialisation.unlinked.configuration.system.services = {
            app.idr.mesh.peers = lib.mkForce {"333333333333" = psk;};
            gateway.idr.mesh.peers = lib.mkForce {"777777777777" = psk;};
            relay.idr.mesh.peers = lib.mkForce {};
          };
        };
        # edge reaches gateway over WireGuard in the other cluster.
        beta = {
          idr.mesh.etcd.other.username = "mesh-beta-other";
          system.services.edge = service {
            id = "777777777777";
            body = "edge";
            peers."666666666666" = psk;
          };
        };
      };

      testScript = ''
        ${meshFixture.script}
        import ipaddress

        other_prefix = "${otherPrefix}"

        def local_address(prefix, service_id):
            return prefix + ":" + ":".join(service_id[index:index + 4] for index in range(0, 12, 4)) + "::"

        # Each service knows the prefix of its cluster.
        assert "${config.nodes.alpha.system.services.app.idr.mesh.ipv6Prefix}" == mesh_prefix
        assert "${config.nodes.alpha.system.services.gateway.idr.mesh.ipv6Prefix}" == other_prefix

        app_address = local_address(mesh_prefix, "222222222222")
        gateway_address = local_address(other_prefix, "666666666666")

        def get(host, service):
            return inside(
                f"curl --noproxy '*' --fail --silent --show-error --connect-timeout 2 --max-time 4 http://{host}:8080/",
                service,
            )

        def links(service):
            return inside("ip -json link show type veth | jq -c '[.[].ifname | select(startswith(\"idrl\"))]'", service)

        def invocations():
            return {
                unit: alpha.succeed(f"systemctl show {unit}.service --property=InvocationID --value").strip()
                for unit in ["app", "gateway", "relay", "idr-mesh-netns@app", "idr-mesh-netns@gateway", "idr-mesh-netns@relay"]
            }

        requests = {
            "gateway": [
                ("666666666666.mesh", "app", "gateway"),
                ("gateway.example.test", "app", "gateway"),
                ("222222222222.mesh", "gateway", "alpha"),
                ("app.example.test", "gateway", "alpha"),
                ("777777777777.mesh", "app", "edge"),
            ],
            "relay": [
                ("888888888888.mesh", "app", "relay"),
                ("222222222222.mesh", "relay", "alpha"),
            ],
        }

        def linked(*peers):
            for peer in peers:
                for host, service, body in requests[peer]:
                    reply = alpha.wait_until_succeeds(get(host, service), timeout=30)
                    assert reply.strip() == body, (host, reply)

        setup_mesh()
        alpha.succeed("systemctl start gateway.service relay.service")
        beta.succeed("systemctl start edge.service")
        wait_registered(alpha, "gateway")
        wait_registered(alpha, "relay")
        wait_registered(beta, "edge")

        with subtest("each cluster holds its own services"):
            other = alpha.succeed(admin + f"get /idr/mesh/{other_prefix}/services/ --prefix --keys-only")
            main = alpha.succeed(admin + f"get {scope} --prefix --keys-only")
            for service_id in ["666666666666", "777777777777"]:
                assert f"/{service_id}/instances/" in other, other
                assert service_id not in main, main
            assert "222222222222" not in other, other
            for machine, peer, service, body in [(beta, "666666666666", "edge", "gateway"), (alpha, "777777777777", "gateway", "edge")]:
                reply = machine.wait_until_succeeds(request(peer, service), timeout=60)
                assert reply.strip() == body, reply

        with subtest("linked services reach each other at their local addresses"):
            linked("gateway", "relay")
            route = alpha.succeed(inside(f"ip -6 route get {gateway_address}", "app")).split()
            assert ipaddress.ip_address(route[route.index("src") + 1]) == ipaddress.ip_address(app_address), route
            # The link carries nothing from other addresses.
            interfaces = json.loads(alpha.succeed(inside("ip -json -6 address show dev idr-mesh", "app")))
            mesh_address = interfaces[0]["addr_info"][0]["local"]
            alpha.fail(inside(f"curl --noproxy '*' --fail --silent --connect-timeout 2 --interface {mesh_address} http://[{gateway_address}]:8080/", "app"))

        with subtest("a link follows its workloads"):
            app = alpha.succeed("systemctl show app.service --property=InvocationID --value")
            alpha.succeed("systemctl stop relay.service")
            alpha.wait_until_succeeds(links("app") + " | jq -e 'length == 1'", timeout=30)
            # app keeps its local address on the remaining link.
            linked("gateway")
            alpha.succeed("systemctl start relay.service")
            linked("gateway", "relay")
            alpha.succeed("systemctl stop gateway.service")
            # app no longer resolves what gateway forwarded.
            alpha.wait_until_fails(inside("getent ahostsv6 777777777777.mesh", "app"), timeout=30)
            alpha.succeed("systemctl start gateway.service")
            linked("gateway", "relay")
            assert alpha.succeed("systemctl show app.service --property=InvocationID --value") == app

        with subtest("removing and adding a link restarts no workload"):
            before = invocations()
            alpha.succeed("/run/booted-system/specialisation/unlinked/bin/switch-to-configuration test", timeout=180)
            assert invocations() == before
            assert alpha.succeed(links("app")).strip() == "[]"
            alpha.wait_until_fails(get("666666666666.mesh", "app"), timeout=30)
            alpha.succeed("/run/booted-system/bin/switch-to-configuration test", timeout=180)
            assert invocations() == before
            linked("gateway", "relay")
      '';
    });
  };
}

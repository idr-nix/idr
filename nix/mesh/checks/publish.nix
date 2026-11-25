top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    socat = lib.getExe pkgs.socat;
    hosts = {
      alpha.address = "2001:db8:1::1";
      beta.address = "2001:db8:1::2";
    };
    # Answers each connection or datagram with the client's address, on a
    # published and an unpublished port.
    echo = pkgs.writeShellScript "mesh-publish-echo" ''
      for proto in TCP6 UDP6; do
        for port in 8443 8444; do
          ${socat} -T 5 "$proto-LISTEN:$port,ipv6only=0,fork,reuseaddr" SYSTEM:'echo "$SOCAT_PEERADDR"' &
        done
      done
      wait -n
    '';
    probeRoot = pkgs.writeTextDir "index.html" "reachable";
  in {
    checks.mesh-publish = pkgs.testers.runNixOSTest ({meshFixture, ...}: {
      imports = [(lib.modules.importApply ./fixture.nix {inherit top;})];
      name = "mesh-publish";

      defaults = {
        environment.systemPackages = [pkgs.socat];
        networking.firewall.filterForward = true;
        # 8090 is open too, but outside the internet access tested below.
        networking.firewall.allowedTCPPorts = [8081 8090];
        systemd.services = lib.listToAttrs (map (port:
          lib.nameValuePair "mesh-publish-host-probe-${port}" {
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              ExecStart = "${lib.getExe pkgs.busybox} httpd -f -p [::]:${port} -h ${probeRoot}";
              DynamicUser = true;
            };
          }) ["8081" "8090"]);
      };

      nodes =
        lib.mapAttrs (name: host: {
          networking.interfaces.eth1.ipv6.addresses = [
            {
              inherit (host) address;
              prefixLength = 64;
            }
          ];
          system.services.front = lib.mkIf (name == "alpha") {
            imports = [top.self.modules.service.mesh];
            idr.mesh = {
              id = "555555555555";
              publish = [
                {
                  proto = "tcp";
                  port = 8443;
                }
                {
                  proto = "udp";
                  port = 8443;
                }
              ];
            };
            process.argv = [echo];
            systemd.service = {
              wantedBy = lib.mkOverride 900 [];
              serviceConfig.DynamicUser = true;
            };
          };
          # A workload with internet access, which beta stands in for, also
          # for names.
          idr.mesh.internet.nameservers = ["2001:db8:1::2"];
          system.services.outbound = lib.mkIf (name == "alpha") {
            imports = [top.self.modules.service.mesh];
            idr.mesh = {
              id = "777777777777";
              internet = {
                enable = true;
                allow = [
                  {
                    proto = "tcp";
                    port = {
                      from = 8080;
                      to = 8081;
                    };
                  }
                ];
              };
            };
            process.argv = [(lib.getExe' pkgs.coreutils "sleep") "infinity"];
            systemd.service = {
              wantedBy = lib.mkOverride 900 [];
              serviceConfig.DynamicUser = true;
            };
          };
          services.coredns = lib.mkIf (name == "beta") {
            enable = true;
            config = ''
              internet.test:53 {
                hosts {
                  2001:db8:1::2 internet.test
                  192.168.1.2 internet.test
                }
              }
            '';
          };
          networking.firewall.allowedUDPPorts = lib.mkIf (name == "beta") [53];
          # Leaves port 53 to CoreDNS.
          services.resolved.settings.Resolve.DNSStubListener = lib.mkIf (name == "beta") false;
          # Changes front's ports to a range, and gives app its first one and
          # internet access.
          specialisation = lib.mkIf (name == "alpha") {
            ports.configuration.system.services = {
              front.idr.mesh.publish = lib.mkForce [
                {
                  proto = "tcp";
                  port = {
                    from = 8443;
                    to = 8444;
                  };
                }
              ];
              app.idr.mesh = {
                publish = [
                  {
                    proto = "tcp";
                    port = 8080;
                  }
                ];
                internet = {
                  enable = true;
                  allow = [
                    {
                      proto = "tcp";
                      port = 8081;
                    }
                  ];
                };
              };
            };
          };
        })
        hosts;

      testScript =
        meshFixture.script
        + ''
          import ipaddress

          setup_mesh()
          alpha.succeed("systemctl start front.service")
          alpha.wait_for_unit("front.service")
          alpha.wait_for_unit("idr-mesh-publish@front.service")

          def target(address):
              return f"[{address}]" if ":" in address else address

          def echo(transport, address, port=8443):
              timeout = ",connect-timeout=2" if transport == "TCP" else ""
              return f"echo ping | socat -T 3 - {transport}:{target(address)}:{port}{timeout} | grep ."

          def link_address(family, service="front"):
              return alpha.succeed(
                  f"ip netns exec idr-mesh-{service} ip -json {family} address show dev idr-publish"
                  + " | jq -r '.[0].addr_info[0].local'"
              ).strip()

          # socat prints the full address, IPv4 clients mapped into IPv6.
          def peer(reply):
              address = ipaddress.ip_address(reply.strip().strip("[]"))
              return getattr(address, "ipv4_mapped", None) or address

          def published_works():
              for address, client in [("2001:db8:1::1", "2001:db8:1::2"), ("192.168.1.1", "192.168.1.2")]:
                  for transport in ["TCP", "UDP"]:
                      reply = beta.wait_until_succeeds(echo(transport, address), timeout=30)
                      assert peer(reply) == ipaddress.ip_address(client), f"{transport} to {address} saw {reply!r}"

          with subtest("published ports reach the workload with the client's address"):
              published_works()

          with subtest("only published ports reach the workload"):
              for address in ["2001:db8:1::1", "192.168.1.1"]:
                  beta.fail(echo("TCP", address, 8444))
              for family in ["-6", "-4"]:
                  address = link_address(family)
                  assert alpha.succeed(echo("TCP", address)).strip() != ""
                  alpha.fail(echo("TCP", address, 8444))

          with subtest("the workload cannot connect out through the link"):
              alpha.succeed("curl --fail --silent --max-time 4 'http://[2001:db8:1::2]:8081/'")
              host_end = alpha.succeed(
                  "ip -json -details link show"
                  + " | jq -r '.[] | select((.ifalias // \"\") | startswith(\"idr-mesh-publish-\")) | .ifname'"
              ).strip()
              assert host_end.startswith("idrp"), host_end
              for address in ["2001:db8:1::2", "192.168.1.2", "2001:db8:1::1", "192.168.1.1"]:
                  alpha.fail(inside(
                      f"curl --fail --silent --max-time 4 'http://{target(address)}:8081/'", "front"
                  ))
              for family in ["-6", "-4"]:
                  gateway = alpha.succeed(
                      f"ip netns exec idr-mesh-front ip -json {family} route show default | jq -r '.[0].gateway'"
                  ).strip()
                  alpha.fail(inside(f"curl --fail --silent --max-time 4 'http://{target(gateway)}:8081/'", "front"))

          with subtest("internet access reaches the allowed ports, also by name, and nothing else"):
              alpha.succeed("systemctl start outbound.service")
              alpha.wait_for_unit("idr-mesh-publish@outbound.service")
              for host in ["internet.test", "[2001:db8:1::2]", "192.168.1.2"]:
                  reply = alpha.wait_until_succeeds(inside(
                      f"curl --fail --silent --max-time 4 'http://{host}:8081/'", "outbound"
                  ), timeout=30)
                  assert reply.strip() == "reachable", reply
              # Open, but not allowed.
              alpha.succeed("curl --fail --silent --max-time 4 'http://[2001:db8:1::2]:8090/'")
              alpha.fail(inside("curl --fail --silent --max-time 4 'http://[2001:db8:1::2]:8090/'", "outbound"))

          with subtest("the link follows the workload"):
              alpha.succeed("systemctl stop front.service")
              alpha.wait_until_fails(f"ip link show dev {host_end}")
              state = alpha.succeed("systemctl show idr-mesh-publish@front.service --property=ActiveState --value")
              assert state.strip() == "inactive", state
              beta.fail(echo("TCP", "2001:db8:1::1"))
              alpha.succeed("systemctl start front.service")
              alpha.wait_for_unit("idr-mesh-publish@front.service")
              published_works()
              alpha.succeed("systemctl restart idr-mesh-publish@front.service")
              alpha.wait_for_unit("front.service")
              published_works()

          with subtest("changing published ports restarts nothing"):
              units = ["front", "app", "idr-mesh-publish@front", "idr-mesh-publish@app"]

              def invocations():
                  return {
                      unit: alpha.succeed(f"systemctl show {unit}.service --property=InvocationID --value").strip()
                      for unit in units
                  }

              def http(address):
                  return f"curl --fail --silent --max-time 4 'http://{target(address)}:8080/'"

              before = invocations()
              alpha.succeed("/run/booted-system/specialisation/ports/bin/switch-to-configuration test", timeout=180)
              assert invocations() == before
              for address in ["2001:db8:1::1", "192.168.1.1"]:
                  for port in [8443, 8444]:
                      beta.wait_until_succeeds(echo("TCP", address, port), timeout=30)
                  beta.fail(echo("UDP", address))
                  assert beta.wait_until_succeeds(http(address), timeout=30).strip() == "alpha"
              # Internet access on app's port does not lead into app's link.
              for family in ["-6", "-4"]:
                  address = link_address(family, "app")
                  alpha.fail(inside(f"curl --fail --silent --max-time 4 'http://{target(address)}:8080/'", "outbound"))
              # app's new internet access needs no restart, also for names.
              reply = alpha.wait_until_succeeds(inside("curl --fail --silent --max-time 4 'http://internet.test:8081/'", "app"), timeout=30)
              assert reply.strip() == "reachable", reply

              alpha.succeed("/run/booted-system/bin/switch-to-configuration test", timeout=180)
              assert invocations() == before
              alpha.fail("ip netns exec idr-mesh-app ip link show dev idr-publish")
              assert "2001:db8:1::2" not in alpha.succeed(inside("cat /etc/resolv.conf", "app"))
              for address in ["2001:db8:1::1", "192.168.1.1"]:
                  beta.fail(echo("TCP", address, 8444))
                  beta.fail(http(address))
              published_works()
        '';
    });
  };
}

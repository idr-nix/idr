top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    addresses = {
      alpha = ["2600:ffff::1" "45.0.0.1"];
      beta = ["2600:ffff::2" "45.0.0.2"];
    };
  in {
    checks.mesh-transport = pkgs.testers.runNixOSTest ({meshFixture, ...}: {
      imports = [(lib.modules.importApply ./fixture.nix {inherit top;})];
      name = "mesh-transport";
      nodes =
        lib.mapAttrs (_: publicAddresses: {
          idr.mesh.publicAddresses = lib.mkForce [];
          # Discovery excludes documentation prefixes; these aliases stay on the test LAN.
          networking.interfaces.eth1 = {
            ipv4.addresses = [
              {
                address = builtins.elemAt publicAddresses 1;
                prefixLength = 24;
              }
            ];
            ipv6.addresses = [
              {
                address = builtins.head publicAddresses;
                prefixLength = 64;
              }
            ];
          };
          boot.kernel.sysctl."net.ipv6.conf.eth1.keep_addr_on_down" = 1;
        })
        addresses;

      testScript =
        meshFixture.script
        + ''
          import base64
          import shlex

          setup_mesh()
          addresses = json.loads('${builtins.toJSON addresses}')

          def registration_query(name):
              return admin + f"get {scope}{instances[name]['id']}/instances/ --prefix --write-out=json"

          def registration(name):
              entries = json.loads(alpha.succeed(registration_query(name)))["kvs"]
              assert len(entries) == 1
              return entries[0]

          def wait_addresses(name, expected):
              predicate = shlex.quote(".state.publicAddresses == " + json.dumps(expected))
              members[name].wait_until_succeeds(
                  "jq -e " + predicate + " /run/idr-mesh-addresses/addresses.json",
                  timeout=30,
              )
              predicate = shlex.quote(
                  ".count == 1 and (.kvs[0].value | @base64d | fromjson | .publicAddresses) == "
                  + json.dumps(expected)
              )
              alpha.wait_until_succeeds(registration_query(name) + " | jq -e " + predicate, timeout=60)

          def packets(family):
              result = json.loads(client.succeed(f"nft -j list counter inet mesh_test_transport {family}"))
              return next(entry["counter"]["packets"] for entry in result["nftables"] if "counter" in entry)

          with subtest("discover public addresses, prefer IPv6, and carry application traffic"):
              for name in members:
                  wait_addresses(name, addresses[name])
              records = {
                  name: json.loads(base64.b64decode(registration(name)["value"]))
                  for name in members
              }
              client_name = min(records, key=lambda name: base64.b64decode(records[name]["publicKey"]))
              server_name = instances[client_name]["peer"]
              client, server = members[client_name], members[server_name]
              port = records[server_name]["port"]
              client.succeed(
                  "nft add table inet mesh_test_transport",
                  "nft 'add chain inet mesh_test_transport output { type filter hook output priority -50; policy accept; }'",
              )
              for family in ["ipv4", "ipv6"]:
                  client.succeed(
                      f"nft add counter inet mesh_test_transport {family}",
                      f"nft add rule inet mesh_test_transport output meta nfproto {family} udp dport {port} counter name {family}",
                  )
              server.succeed(
                  "nft add table inet mesh_test_transport",
                  "nft 'add chain inet mesh_test_transport input { type filter hook input priority -50; policy accept; }'",
                  f"nft add rule inet mesh_test_transport input ip daddr {addresses[server_name][1]} udp dport 30000-32767 drop",
              )
              client.wait_until_succeeds(request(server_name), timeout=90)
              assert packets("ipv6") > 0
              ipv4_before = packets("ipv4")
              pids = {
                  name: machine.succeed("systemctl show app.service --property=MainPID --value")
                  for name, machine in members.items()
              }

          with subtest("fail over established traffic when the preferred address fails its UDP health check"):
              server.succeed(
                  "nft flush chain inet mesh_test_transport input",
                  f"nft add rule inet mesh_test_transport input ip6 daddr {addresses[server_name][0]} udp dport 30000-32767 drop",
              )
              client.wait_until_succeeds(request(server_name), timeout=60)
              assert packets("ipv4") > ipv4_before
              assert json.loads(base64.b64decode(registration(server_name)["value"]))["publicAddresses"] == addresses[server_name]

          with subtest("refresh discovery after an uplink disconnects and reconnects"):
              server.succeed("ip link set eth1 down")
              server.wait_until_succeeds("jq -e '.state.publicAddresses == []' /run/idr-mesh-addresses/addresses.json", timeout=30)
              server.succeed("ip link set eth1 up")
              wait_addresses(server_name, addresses[server_name])
              client.wait_until_succeeds(request(server_name), timeout=60)

          with subtest("update remote endpoints and local sources without restarting the application"):
              for name in [server_name, client_name]:
                  previous = addresses[name][1]
                  replacement = previous.rsplit(".", 1)[0] + "." + str(int(previous.rsplit(".", 1)[1]) + 10)
                  members[name].succeed(
                      f"ip address del {previous}/24 dev eth1",
                      f"ip address add {replacement}/24 dev eth1",
                  )
                  addresses[name][1] = replacement
                  wait_addresses(name, addresses[name])
                  client.wait_until_succeeds(request(server_name), timeout=60)
              endpoint = server.succeed("ip netns exec idr-mesh-app wg show idr-mesh endpoints").split()[1]
              assert endpoint.rsplit(":", 1)[0] == addresses[client_name][1]

          with subtest("ignore host WireGuard link and mesh namespace address changes"):
              wait_mesh_idle(client)
              file_before = client.succeed("stat -c '%i:%y' /run/idr-mesh-addresses/addresses.json")
              revision_before = registration(client_name)["mod_revision"]
              collector_before = collections(client)
              client.succeed(
                  "ip link add mesh-test type wireguard",
                  "ip link set mesh-test up",
                  "ip link set mesh-test netns idr-mesh-app",
                  "ip -n idr-mesh-app address add fd00:ffff::1/128 dev mesh-test",
                  "ip -n idr-mesh-app link del mesh-test",
              )
              retry(lambda _: collections(client) != collector_before, timeout_seconds=30)
              wait_mesh_idle(client)
              assert client.succeed("stat -c '%i:%y' /run/idr-mesh-addresses/addresses.json") == file_before
              assert registration(client_name)["mod_revision"] == revision_before
              for name, machine in members.items():
                  assert machine.succeed(request(instances[name]["peer"])).strip() == instances[name]["peer"]
                  assert machine.succeed(
                      "systemctl show app.service --property=MainPID --value"
                  ) == pids[name]
        '';
    });

    checks.mesh-transport-source = pkgs.testers.runNixOSTest ({meshFixture, ...}: let
      sources = {
        alpha = "10.20.0.1";
        beta = "10.20.0.2";
      };
    in {
      imports = [(lib.modules.importApply ./fixture.nix {inherit top;})];
      name = "mesh-transport-source";
      nodes =
        lib.mapAttrs (_: address: {
          networking.interfaces.eth1.ipv4.addresses = [
            {
              inherit address;
              prefixLength = 24;
            }
          ];
        })
        sources;

      testScript =
        meshFixture.script
        + ''
          import base64
          import shlex
          import time

          sources = json.loads('${builtins.toJSON sources}')
          start_all()
          for name, machine in members.items():
              machine.wait_for_unit("multi-user.target")
              destination = instances[instances[name]["peer"]]["address"]
              machine.succeed(
                  f"ip route add {destination}/32 dev eth1 src {sources[name]} table 100",
                  "ip rule add priority 100 ipproto udp lookup 100",
              )
          setup_mesh()

          public_keys = {
              name: machine.succeed("cat /run/idr-mesh-keys/app/public-key").strip()
              for name, machine in members.items()
          }
          client_name = min(public_keys, key=lambda name: base64.b64decode(public_keys[name]))
          server_name = instances[client_name]["peer"]
          client, server = members[client_name], members[server_name]
          old_source = sources[client_name]
          new_source = "10.20.0.10"
          destination = instances[server_name]["address"]

          def registration_revision():
              result = json.loads(alpha.succeed(
                  admin + f"get {scope}{instances[client_name]['id']}/instances/ --prefix --write-out=json"
              ))
              assert len(result["kvs"]) == 1
              return result["kvs"][0]["mod_revision"]

          with subtest("establish traffic with fixed advertisements and a private source address"):
              client.wait_until_succeeds(request(server_name), timeout=90)
              server.wait_until_succeeds(
                  "ip netns exec idr-mesh-app wg show idr-mesh endpoints | grep -F " + shlex.quote(old_source + ":"),
                  timeout=60,
              )
              wait_mesh_idle(client)
              addresses_before = json.loads(client.succeed("cat /run/idr-mesh-addresses/addresses.json"))["state"]
              assert addresses_before["publicAddresses"] == [instances[client_name]["address"]]
              assert old_source in addresses_before["localAddresses"]
              revision_before = registration_revision()
              pids = {
                  name: machine.succeed("systemctl show app.service --property=MainPID --value")
                  for name, machine in members.items()
              }

          with subtest("refresh UDP sessions after only the local source address changes"):
              changed = time.monotonic()
              client.succeed(
                  f"ip address add {new_source}/24 dev eth1",
                  f"ip route replace {destination}/32 dev eth1 src {new_source} table 100",
                  f"ip address del {old_source}/24 dev eth1",
                  f"ping -c 1 -W 3 -I {new_source} {destination}",
              )
              server.succeed(f"ping -c 1 -W 3 {instances[client_name]['address']}")
              client.wait_until_succeeds(request(server_name), timeout=60)
              assert time.monotonic() - changed < 60
              endpoint = server.succeed("ip netns exec idr-mesh-app wg show idr-mesh endpoints").split()[1]
              assert endpoint.rsplit(":", 1)[0] == new_source
              # The kernel may move to the new source before the collector records it.
              client.wait_until_succeeds(
                  "jq -e " + shlex.quote(f'(.state.localAddresses | index("{new_source}")) != null and (.state.localAddresses | index("{old_source}")) == null')
                  + " /run/idr-mesh-addresses/addresses.json",
                  timeout=30,
              )
              addresses_after = json.loads(client.succeed("cat /run/idr-mesh-addresses/addresses.json"))["state"]
              assert addresses_after["publicAddresses"] == addresses_before["publicAddresses"]
              assert new_source in addresses_after["localAddresses"]
              assert old_source not in addresses_after["localAddresses"]
              assert registration_revision() == revision_before

          client.succeed(
              f"ip address add {old_source}/24 dev eth1",
              f"ip route add {destination}/32 dev eth1 src {new_source} table 101",
              "nft add table inet mesh_test_source",
              "nft 'add chain inet mesh_test_source output { type filter hook output priority -10; policy accept; }'",
          )
          client.wait_until_succeeds(
              "jq -e " + shlex.quote(f'.state.localAddresses | index("{old_source}") != null')
              + " /run/idr-mesh-addresses/addresses.json",
              timeout=30,
          )

          def change_routing(command, source, previous_source):
              wait_mesh_idle(client)
              addresses_before = json.loads(client.succeed("cat /run/idr-mesh-addresses/addresses.json"))["state"]
              assert all(address in addresses_before["localAddresses"] for address in [source, previous_source])
              changed = time.monotonic()
              client.succeed(
                  "nft flush chain inet mesh_test_source output",
                  f"nft add rule inet mesh_test_source output ip saddr {previous_source} ip daddr {destination} udp dport 30000-32767 drop",
                  command,
                  f"ping -c 1 -W 3 -I {source} {destination}",
              )
              server.succeed(f"ping -c 1 -W 3 {instances[client_name]['address']}")
              client.wait_until_succeeds(request(server_name), timeout=60)
              assert time.monotonic() - changed < 60
              endpoint = server.succeed("ip netns exec idr-mesh-app wg show idr-mesh endpoints").split()[1]
              assert endpoint.rsplit(":", 1)[0] == source
              addresses_after = json.loads(client.succeed("cat /run/idr-mesh-addresses/addresses.json"))["state"]
              for field in ["publicAddresses", "localAddresses"]:
                  assert addresses_after[field] == addresses_before[field]
              assert registration_revision() == revision_before

          with subtest("refresh UDP sessions after a preferred source changes while both addresses remain assigned"):
              change_routing(
                  f"ip route replace {destination}/32 dev eth1 src {old_source} table 100",
                  old_source,
                  new_source,
              )

          with subtest("refresh UDP sessions after a policy rule selects another existing route"):
              change_routing("ip rule add priority 90 ipproto udp lookup 101", new_source, old_source)

          with subtest("ignore local-table routes"):
              wait_mesh_idle(client)
              addresses_before = client.succeed("cat /run/idr-mesh-addresses/addresses.json")
              for operation in ["add", "del"]:
                  collector_before = collections(client)
                  client.succeed(f"ip -6 route {operation} local fd00:ffff:fffe::1/128 dev lo table local")
                  retry(lambda _: collections(client) != collector_before, timeout_seconds=30)
                  wait_mesh_idle(client)
                  assert client.succeed("cat /run/idr-mesh-addresses/addresses.json") == addresses_before
                  assert registration_revision() == revision_before
              for name, machine in members.items():
                  assert machine.succeed(request(instances[name]["peer"])).strip() == instances[name]["peer"]
                  assert machine.succeed(
                      "systemctl show app.service --property=MainPID --value"
                  ) == pids[name]
        '';
    });
  };
}

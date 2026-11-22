top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
  in {
    checks.mesh-connectivity = assert import ./password-recipients.nix {
      inherit top lib;
      inherit (pkgs.stdenv.hostPlatform) system;
    };
      pkgs.testers.runNixOSTest ({meshFixture, ...}: {
        imports = [(lib.modules.importApply ./fixture.nix {inherit top;})];
        name = "mesh-connectivity";
        nodes.alpha.system.services.app.idr.mesh.peers =
          lib.genAttrs
          (lib.genList (index: lib.fixedWidthString 12 "0" (lib.toLower (lib.toHexString (index + 1)))) 128)
          (_: {psk = meshFixture.secret "psk";});
        testScript =
          meshFixture.script
          + ''
            import base64
            import hashlib
            import ipaddress
            import time

            setup_mesh()
            lease_seconds = ${toString meshFixture.leaseTTLSeconds}

            with subtest("register authenticated instances with 129 declared peers on alpha"):
                alpha.wait_until_succeeds(
                    admin + f"get {scope} --prefix --write-out=json | jq -e '.count == 2'"
                )
                public_keys = {}
                mesh_addresses = {}
                expected_hash = hashlib.sha256(base64.b64decode(initial_psk)).hexdigest()
                for entry in registrations()["kvs"]:
                    key = base64.b64decode(entry["key"]).decode()
                    value = json.loads(base64.b64decode(entry["value"]))
                    service_id, instance_id = key.removeprefix(scope).split("/instances/")
                    name = next(name for name, instance in instances.items() if instance["id"] == service_id)
                    declared_peers = json.loads(members[name].succeed("cat /etc/idr-mesh/settings/app.json"))["peers"]
                    assert len(declared_peers) == (129 if name == "alpha" else 1)
                    assert int(entry["lease"]) != 0
                    assert value["publicAddresses"] == [instances[name]["address"]]
                    assert 30001 <= value["port"] <= 32767 and value["healthPort"] == 30000
                    assert value["peers"] == {peer_id: {"pskHash": expected_hash} for peer_id in declared_peers}
                    public_keys[name] = value["publicKey"]
                    suffix = service_id + instance_id
                    mesh_addresses[name] = ipaddress.IPv6Address(
                        mesh_prefix + ":" + ":".join(suffix[index:index + 4] for index in range(0, 20, 4))
                    )

            beta_etcd = etcd + "--user=mesh-beta:public-test-mesh-beta "

            with subtest("limit each agent's etcd user to its services and their peers"):
                alpha_service = scope + instances["alpha"]["id"] + "/"
                alpha_entry = next(
                    entry for entry in registrations()["kvs"] if base64.b64decode(entry["key"]).decode().startswith(alpha_service)
                )
                alpha_key = base64.b64decode(alpha_entry["key"]).decode()
                alpha_instance = alpha_key.rsplit("/", 1)[1]
                alpha_public = base64.b64decode(public_keys["alpha"]).hex()
                beta.succeed(beta_etcd + f"get {alpha_service} --prefix")
                beta.fail(beta_etcd + f"get {scope}000000000001/ --prefix")
                beta.fail(beta_etcd + f"put {alpha_service}instances/ffffffff forged")
                beta.fail(beta_etcd + f"del {alpha_key}")
                beta.fail(beta_etcd + f"put {alpha_service}retirements/{alpha_instance}/{alpha_public} forged")
                beta.fail(beta_etcd + f"lease revoke {int(alpha_entry['lease']):x}")
                current = [entry for entry in registrations()["kvs"] if base64.b64decode(entry["key"]).decode() == alpha_key]
                assert [entry["mod_revision"] for entry in current] == [alpha_entry["mod_revision"]]

            def peer_handshake(name):
                key, timestamp = members[name].succeed(
                    "ip netns exec idr-mesh-app wg show idr-mesh latest-handshakes"
                ).split()
                assert key == public_keys[instances[name]["peer"]]
                return int(timestamp)

            with subtest("resolve and connect through isolated DNS and WireGuard"):
                application_pids = {}
                psk_states = {}
                psk_state_command = "sha256sum /var/lib/idr-mesh-psk/app/[0-9a-f]*.json"
                for name, machine in members.items():
                    application_pids[name] = machine.succeed(
                        "systemctl show app.service --property=MainPID --value"
                    ).strip()
                    pid = application_pids[name]
                    namespaces = [machine.succeed(f"readlink /proc/{target}/ns/net").strip() for target in ["1", pid]]
                    assert len(set(namespaces)) == 2
                    assert machine.succeed(f"stat -Lc %i /proc/{pid}/ns/net").strip() == machine.succeed(
                        "stat -Lc %i /run/netns/idr-mesh-app"
                    ).strip()
                    assert machine.succeed("stat -Lc %i /run/netns/idr-dns").strip() != machine.succeed(
                        "stat -Lc %i /run/netns/idr-mesh-app"
                    ).strip()
                    interfaces = json.loads(machine.succeed("ip -n idr-mesh-app -j link show"))
                    assert {interface["ifname"] for interface in interfaces} == {"lo", "idr-mesh", "idr-dns"}
                    peer = instances[name]["peer"]
                    machine.wait_until_succeeds(request(peer), timeout=90)
                    assert machine.succeed(request(peer)).strip() == peer
                    answers = machine.succeed(inside(f"getent ahostsv6 {instances[peer]['id']}.mesh"))
                    assert {ipaddress.IPv6Address(line.split()[0]) for line in answers.splitlines()} == {mesh_addresses[peer]}
                    assert peer_handshake(name) > 0
                    transfer = machine.succeed("ip netns exec idr-mesh-app wg show idr-mesh transfer").split()
                    assert int(transfer[1]) > 0 and int(transfer[2]) > 0
                    wait_mesh_idle(machine)
                    psk_states[name] = machine.succeed(psk_state_command)
                initiator = min(public_keys, key=lambda name: base64.b64decode(public_keys[name]))
                endpoint = members[initiator].succeed("ip netns exec idr-mesh-app wg show idr-mesh endpoints").split()[1]
                assert endpoint.rsplit(":", 1)[0] == instances[instances[initiator]["peer"]]["address"], endpoint

            with subtest("retain traffic when one host loses etcd and the other observes its lease expire"):
                beta.succeed(
                    "nft add table inet mesh_test_outage",
                    "nft 'add chain inet mesh_test_outage output { type filter hook output priority -50; policy accept; }'",
                    "nft add rule inet mesh_test_outage output ip daddr 192.168.1.1 tcp dport 2379 reject with tcp reset",
                )
                def traffic_survives_until_expiry(_):
                    for name, machine in members.items():
                        assert machine.succeed(request(instances[name]["peer"])).strip() == instances[name]["peer"]
                        assert machine.succeed("systemctl show app.service --property=MainPID --value").strip() == application_pids[name]
                    remaining = registrations().get("kvs", [])
                    assert len(remaining) in (1, 2)
                    if len(remaining) == 2:
                        return False
                    assert json.loads(base64.b64decode(remaining[0]["value"]))["publicKey"] == public_keys["alpha"]
                    return True

                retry(traffic_survives_until_expiry, timeout_seconds=lease_seconds + 30)
                alpha.wait_until_succeeds(
                    "jq -e '.state.peers | length == 1 and .[0].registrationPresent == false' "
                    "/run/idr-mesh-agent/peers/app.json"
                )
                for name, machine in members.items():
                    assert machine.succeed(request(instances[name]["peer"])).strip() == instances[name]["peer"]
                    assert machine.succeed(psk_state_command) == psk_states[name]

            with subtest("retain DNS and WireGuard when the expired instance loses its network"):
                def transport_state():
                    return beta.succeed("jq -c '.state | {localAddresses, routing}' /run/idr-mesh-addresses/addresses.json").strip()

                connected_state = transport_state()
                beta.succeed("ip link set eth1 down")
                alpha.fail(request("beta"))
                # The last WireGuard session must expire before transport returns (REJECT_AFTER_TIME is 180s).
                offline_seconds = max(lease_seconds, 185)
                offline_until = time.monotonic() + offline_seconds
                def retained_while_offline(_):
                    answers = alpha.succeed(inside(f"getent ahostsv6 {instances['beta']['id']}.mesh"))
                    assert {ipaddress.IPv6Address(line.split()[0]) for line in answers.splitlines()} == {mesh_addresses["beta"]}
                    assert alpha.succeed("ip netns exec idr-mesh-app wg show idr-mesh peers").split() == [public_keys["beta"]]
                    return time.monotonic() >= offline_until and transport_state() != connected_state

                retry(retained_while_offline, timeout_seconds=offline_seconds + 30)
                offline_state = transport_state()
                previous_handshakes = {name: peer_handshake(name) for name in members}
                beta.succeed("ip link set eth1 up")
                retry(lambda _: transport_state() != offline_state, timeout_seconds=30)
                for name, machine in members.items():
                    machine.wait_until_succeeds(request(instances[name]["peer"]), timeout=60)
                    assert peer_handshake(name) > previous_handshakes[name]
                beta.succeed("nft delete table inet mesh_test_outage")
                alpha.wait_until_succeeds(
                    admin + f"get {scope} --prefix --write-out=json | jq -e '.count == 2'",
                    timeout=90,
                )
                alpha.wait_until_succeeds(
                    "jq -e '.state.peers | length == 1 and .[0].registrationPresent == true' "
                    "/run/idr-mesh-agent/peers/app.json"
                )
                for name, machine in members.items():
                    assert machine.succeed(request(instances[name]["peer"])).strip() == instances[name]["peer"]
                    wait_mesh_idle(machine)
          '';
      });
  };
}

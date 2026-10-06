top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.etcd-cluster = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./etcd-fixture.nix {inherit top;})];
      name = "etcd-cluster";
      defaults = {pkgs, ...}: {environment.systemPackages = [pkgs.curl];};
      nodes =
        (lib.genAttrs ["alpha" "beta" "gamma"] (name: {
          idr.etcd.instances.${name}.allowedIPs = lib.mkForce ["192.168.1.0/30" "2001:db8:1::/126"];
        }))
        // {
          outsider.networking.interfaces.eth1.ipv6.addresses = [
            {
              address = "2001:db8:1::4";
              prefixLength = 64;
            }
          ];
        };
      testScript = ''
        import json

        start_all()
        members = {"alpha": alpha, "beta": beta, "gamma": gamma}
        for name, machine in members.items():
            machine.wait_for_unit(f"idr-etcd-{name}.service")
        alpha.wait_until_succeeds("etcdctl endpoint health --cluster")

        with subtest("bootstrap three HTTPS members connected through WireGuard"):
            listing = json.loads(alpha.succeed("etcdctl member list --write-out=json"))["members"]
            assert len(listing) == 3
            assert {member["name"] for member in listing} == set(members)
            for name, machine in members.items():
                assert machine.succeed("systemctl show systemd-networkd --property=NRestarts --value").strip() == "0"
                # Quorum health can precede the last pair's WireGuard handshake.
                machine.wait_until_succeeds(
                    "wg show idr-etcd-wg latest-handshakes | "
                    "awk '$2 > 0 { ready++ } END { exit !(NR == 2 && ready == 2) }'",
                    timeout=60,
                )
                handshakes = machine.succeed("wg show idr-etcd-wg latest-handshakes").splitlines()
                assert len(handshakes) == 2
                assert all(int(line.split()[1]) > 0 for line in handshakes)
                machine.succeed(f"mountpoint /p1/etcd-{name}")
                machine.succeed(f"mountpoint /var/lib/private/idr-etcd-{name}")
            alpha.succeed("etcdctl put /application/persistent before-reboot")
            for name, machine in members.items():
                assert machine.succeed(
                    f"ETCDCTL_ENDPOINTS=https://etcd-{name}.example.test:2379 etcdctl "
                    "get /application/persistent --print-value-only"
                ).strip() == "before-reboot"

        with subtest("allow configured IPv4 and IPv6 clients and refuse clients outside allowedIPs"):
            outsider.wait_for_unit("multi-user.target")
            https = "curl --fail --silent --show-error --max-time 3 --cacert $ETCDCTL_CACERT "
            for name, suffix in [("alpha", "1"), ("gamma", "3")]:
                outsider.wait_until_succeeds(f"ping -c 1 192.168.1.{suffix}")
                outsider.wait_until_succeeds(f"ping -6 -c 1 2001:db8:1::{suffix}")
                url = f"https://etcd-{name}.example.test:2379/health"
                ipv4 = f"--resolve 'etcd-{name}.example.test:2379:192.168.1.{suffix}' "
                ipv6 = f"--resolve 'etcd-{name}.example.test:2379:[2001:db8:1::{suffix}]' "
                beta.succeed(https + ipv4 + url, https + ipv6 + url)
                outsider.fail(https + ipv4 + url, https + ipv6 + url)

        with subtest("continue writing after losing the elected leader"):
            status = json.loads(alpha.succeed("etcdctl endpoint status --write-out=json"))
            leader_id = status[0]["Status"]["leader"]
            leader_name = next(member["name"] for member in listing if member["ID"] == leader_id)
            leader = members[leader_name]
            survivors = [(name, machine) for name, machine in members.items() if name != leader_name]
            leader.shutdown()
            endpoint = f"ETCDCTL_ENDPOINTS=https://etcd-{survivors[0][0]}.example.test:2379"
            client = survivors[0][1]
            client.wait_until_succeeds(f"{endpoint} etcdctl put /application/quorum leader-replaced")
            assert client.succeed(
                f"{endpoint} etcdctl get /application/persistent --print-value-only"
            ).strip() == "before-reboot"
            leader.start()
            leader.wait_for_unit(f"idr-etcd-{leader_name}.service")
            leader.wait_until_succeeds("etcdctl endpoint health --cluster")
            assert leader.succeed(
                f"ETCDCTL_ENDPOINTS=https://etcd-{leader_name}.example.test:2379 etcdctl "
                "get /application/quorum --print-value-only"
            ).strip() == "leader-replaced"

        with subtest("retain committed data when all members restart"):
            for machine in members.values():
                machine.shutdown()
            start_all()
            for name, machine in members.items():
                machine.wait_for_unit(f"idr-etcd-{name}.service")
            alpha.wait_until_succeeds("etcdctl endpoint health --cluster")
            assert alpha.succeed("etcdctl get /application/persistent --print-value-only").strip() == "before-reboot"
            assert alpha.succeed("etcdctl get /application/quorum --print-value-only").strip() == "leader-replaced"
      '';
    };
  };
}

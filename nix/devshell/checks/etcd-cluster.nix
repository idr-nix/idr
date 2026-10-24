top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.etcd-cluster = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./etcd-fixture.nix {inherit top;})];
      name = "etcd-cluster";
      defaults = {pkgs, ...}: {environment.systemPackages = [pkgs.curl];};
      nodes =
        (lib.genAttrs ["alpha" "beta" "gamma"] (name: {config, ...}: {
          idr.etcd.clusters.main.instances.${name} = {
            allowedIPs = lib.mkForce ["192.168.1.0/30" "2001:db8:1::/126"];
            autoCompactionRetention = "5s";
          };
          idr.etcd.clusters.test.instances.${name} = {
            dataDir = "/p1/etcd-test-${name}";
            cert = config.idr.secrets."${name}-cert";
            certKey = config.idr.secrets."${name}-cert-key";
            clusterToken = "public-documentation-test";
            publicHostname = "etcd-${name}.example.test";
            publicPort = 2381;
            allowedIPs = ["192.168.1.0/24"];
            peers = lib.genAttrs (lib.filter (peer: peer != name) ["alpha" "beta" "gamma"]) (_: {});
          };
          virtualisation.emptyDiskImages = [
            {
              size = 256;
              driveConfig.deviceExtraOpts.serial = "etcd-test-data";
            }
          ];
          fileSystems."/p1/etcd-test-${name}" = {
            device = "/dev/disk/by-id/virtio-etcd-test-data";
            fsType = "ext4";
            autoFormat = true;
          };
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
        from concurrent.futures import ThreadPoolExecutor

        start_all()
        members = {"alpha": alpha, "beta": beta, "gamma": gamma}
        test_client = "ETCDCTL_ENDPOINTS=https://etcd-alpha.example.test:2381 etcdctl "
        for name, machine in members.items():
            machine.wait_for_unit(f"idr-etcd-main@{name}.service")
            machine.wait_for_unit(f"idr-etcd-test@{name}.service")
        alpha.wait_until_succeeds("etcdctl endpoint health --cluster")
        alpha.wait_until_succeeds(test_client + "endpoint health --cluster")

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
                machine.succeed(f"mountpoint /var/lib/private/idr-etcd-main@{name}")
            alpha.succeed("etcdctl put /application/persistent before-reboot")
            for name, machine in members.items():
                assert machine.succeed(
                    f"ETCDCTL_ENDPOINTS=https://etcd-{name}.example.test:2379 etcdctl "
                    "get /application/persistent --print-value-only"
                ).strip() == "before-reboot"

        with subtest("isolate clusters with the same member names on one WireGuard interface"):
            test_listing = json.loads(alpha.succeed(test_client + "member list --write-out=json"))["members"]
            assert {member["name"] for member in test_listing} == set(members)
            assert not {
                url for member in listing for url in member["peerURLs"]
            } & {url for member in test_listing for url in member["peerURLs"]}
            alpha.succeed(test_client + "put /application/persistent second-cluster")
            for name, machine in members.items():
                assert machine.succeed("wg show interfaces").strip() == "idr-etcd-wg"
                machine.succeed(f"mountpoint /p1/etcd-test-{name}")
                machine.succeed(f"mountpoint /var/lib/private/idr-etcd-test@{name}")
                for port, expected in [(2379, "before-reboot"), (2381, "second-cluster")]:
                    assert machine.succeed(
                        f"ETCDCTL_ENDPOINTS=https://etcd-{name}.example.test:{port} etcdctl "
                        "get /application/persistent --print-value-only"
                    ).strip() == expected

        with subtest("automatically compact old revisions while retaining current values"):
            original = json.loads(alpha.succeed("etcdctl put /application/compaction old --write-out=json"))
            revision = original["header"]["revision"]
            alpha.succeed("etcdctl put /application/compaction current")
            alpha.wait_until_succeeds(
                f"(etcdctl get /application/compaction --rev={revision} 2>&1 || true) "
                '| grep -F "etcdserver: mvcc: required revision has been compacted"',
                timeout=30,
            )
            for name, machine in members.items():
                assert machine.succeed(
                    f"ETCDCTL_ENDPOINTS=https://etcd-{name}.example.test:2379 etcdctl "
                    "get /application/compaction --print-value-only"
                ).strip() == "current"

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
            leader.wait_for_unit(f"idr-etcd-main@{leader_name}.service")
            leader.wait_until_succeeds("etcdctl endpoint health --cluster")
            assert leader.succeed(
                f"ETCDCTL_ENDPOINTS=https://etcd-{leader_name}.example.test:2379 etcdctl "
                "get /application/quorum --print-value-only"
            ).strip() == "leader-replaced"

        with subtest("retain committed data when all members restart"):
            # Stop independent VMs together, then wait for every member to be
            # powered off before starting the cluster again.
            with ThreadPoolExecutor(max_workers=len(members)) as executor:
                shutdowns = [executor.submit(machine.shutdown) for machine in members.values()]
                for shutdown in shutdowns:
                    shutdown.result()
            start_all()
            for name, machine in members.items():
                machine.wait_for_unit(f"idr-etcd-main@{name}.service")
                machine.wait_for_unit(f"idr-etcd-test@{name}.service")
            alpha.wait_until_succeeds("etcdctl endpoint health --cluster")
            alpha.wait_until_succeeds(test_client + "endpoint health --cluster")
            assert alpha.succeed("etcdctl get /application/persistent --print-value-only").strip() == "before-reboot"
            assert alpha.succeed("etcdctl get /application/quorum --print-value-only").strip() == "leader-replaced"
            assert alpha.succeed(test_client + "get /application/persistent --print-value-only").strip() == "second-cluster"
      '';
    };
  };
}

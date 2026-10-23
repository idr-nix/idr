top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.etcd-proxy = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./etcd-auth-fixture.nix {inherit top;})];
      name = "etcd-proxy";
      nodes.alpha.systemd.services.idr-etcd-alpha.environment.ETCD_AUTH_TOKEN_TTL = "15";
      nodes.beta.systemd.services.idr-etcd-beta.environment.ETCD_AUTH_TOKEN_TTL = "15";
      nodes.gamma.systemd.services.idr-etcd-gamma.environment.ETCD_AUTH_TOKEN_TTL = "15";
      nodes.proxy = {
        idr.etcd.proxy.application = {
          endpoints = [
            {
              domain = "etcd-alpha.example.test";
              ip = "192.168.1.1";
            }
            {
              domain = "etcd-beta.example.test";
              ip = "192.168.1.2";
            }
            {
              domain = "etcd-gamma.example.test";
              ip = "192.168.1.3";
            }
          ];
          caCert = ./fixtures/etcd/ca.pem;
        };
      };
      testScript = ''
        import ipaddress
        import json
        import time

        start_all()
        for name, machine in [("alpha", alpha), ("beta", beta), ("gamma", gamma)]:
            machine.wait_for_unit(f"idr-etcd-{name}.service")
        controller = alpha.succeed("systemctl list-units 'idr-etcd-rbac-*' --no-legend --plain | awk '{print $1}'").strip()
        alpha.wait_for_unit(controller)
        proxy.wait_for_unit("idr-etcd-proxy-application.service")
        local = "env -u ETCDCTL_CACERT ETCDCTL_ENDPOINTS=http://application.etcd.internal:65535 etcdctl "
        application = local + "--user=application:public-test-application "
        retired = local + "--user=retired:public-test-application "
        admin = "ETCDCTL_ENDPOINTS=https://etcd-alpha.example.test:2379 etcdctl --user=root:public-test-root "

        def assert_denied(command, reason):
            output = proxy.fail(command + " 2>&1")
            assert reason in output, output

        with subtest("use the documented local IPv6 proxy with application credentials"):
            address = proxy.succeed("getent ahostsv6 application.etcd.internal | head -1 | awk '{print $1}'").strip()
            assert ipaddress.ip_address(address).version == 6
            proxy.wait_until_succeeds(application + "put /application/proxy via-local-proxy")
            assert alpha.succeed(
                "etcdctl --user=application:public-test-application get /application/proxy --print-value-only"
            ).strip() == "via-local-proxy"
            assert proxy.succeed(application + "get /application/proxy --print-value-only").strip() == "via-local-proxy"
            proxy.fail(local + "get /application/proxy")
            proxy.fail(application + "put /outside-application denied")

        with subtest("authorize serializable reads after an authorized caller warms the proxy"):
            query = "get /application/ --prefix --print-value-only"
            # The upstream proxy also caches successful linearizable reads.
            assert proxy.succeed(application + query).strip() == "via-local-proxy"
            assert_denied(local + query + " --consistency=s", "etcdserver: user name is empty")
            assert_denied(retired + query + " --consistency=s", "etcdserver: permission denied")
            assert proxy.succeed(application + query + " --consistency=s").strip() == "via-local-proxy"

        with subtest("authorize reads of values returned by transactions"):
            proxy.succeed(application + "put /application/txn-cache from-transaction")
            # Range responses inside a transaction can populate the same cache.
            output = proxy.succeed("printf '\\nget /application/txn-cache\\n\\n\\n' | " + application + "txn")
            assert "SUCCESS" in output and "from-transaction" in output, output
            query = "get /application/txn-cache --consistency=s --print-value-only"
            assert_denied(local + query, "etcdserver: user name is empty")
            assert_denied(retired + query, "etcdserver: permission denied")
            assert proxy.succeed(application + query).strip() == "from-transaction"

        with subtest("honor permission revocation performed directly on the cluster"):
            query = "get /application/proxy --consistency=s --print-value-only"
            assert proxy.succeed(application + query).strip() == "via-local-proxy"
            # This mutation bypasses the proxy and its local cache invalidation.
            alpha.succeed(admin + "role revoke-permission application /application/ --prefix")
            for name in ["alpha", "beta", "gamma"]:
                direct = (
                    f"ETCDCTL_ENDPOINTS=https://etcd-{name}.example.test:2379 "
                    "etcdctl --user=application:public-test-application "
                )
                # Wait for every possible upstream to apply the revocation.
                # etcdctl is expected to fail; match its error under pipefail.
                alpha.wait_until_succeeds(
                    "(" + direct + query + ' 2>&1 || true) | grep -F "Error: etcdserver: permission denied"',
                    timeout=30,
                )
            assert_denied(application + query, "etcdserver: permission denied")
            alpha.succeed(admin + "role grant-permission application readwrite /application/ --prefix")
            proxy.wait_until_succeeds(application + "get /application/proxy")

        with subtest("keep authenticated leases alive beyond their original TTL"):
            granted = json.loads(proxy.succeed(application + "lease grant 15 --write-out=json"))
            lease = format(granted["ID"], "x")
            lease_ttl = granted["TTL"]
            lease_env = "env ETCDCTL_DIAL_TIMEOUT=30s "
            proxy.succeed(application + f"put /application/lease alive --lease={lease}")
            proxy.succeed(
                "systemd-run --unit=etcd-lease-keepalive --property=Type=exec "
                "--setenv=PATH=/run/current-system/sw/bin "
                "--property=StandardOutput=append:/tmp/etcd-lease-keepalive.json "
                + lease_env + application + f"lease keep-alive {lease} --write-out=json"
            )
            proxy.wait_for_unit("etcd-lease-keepalive.service")
            proxy.wait_until_succeeds("test -s /tmp/etcd-lease-keepalive.json", timeout=30)
            # Positive keepalive replies alone can conceal failed renewal.
            deadline = time.monotonic() + 2 * lease_ttl
            while time.monotonic() < deadline:
                proxy.succeed("systemctl is-active --quiet etcd-lease-keepalive.service")
                assert alpha.succeed(admin + "get /application/lease --print-value-only").strip() == "alive"
                time.sleep(2)

        with subtest("reject unauthorized renewal while the owner's keepalive stream is active"):
            # etcdctl 3.6.11 ignores command-timeout for keepalive; bound these probes externally.
            assert_denied(
                "timeout 30s " + lease_env + local + f"lease keep-alive {lease} --once",
                "etcdserver: user name is empty",
            )
            assert_denied(
                "timeout 30s " + lease_env + retired + f"lease keep-alive {lease} --once",
                "etcdserver: permission denied",
            )

        with subtest("expire the lease and its key after the keepalive client stops"):
            proxy.succeed(
                "systemctl is-active --quiet etcd-lease-keepalive.service",
                "systemctl stop etcd-lease-keepalive.service",
            )
            alpha.wait_until_succeeds(
                admin + f"lease timetolive {lease} --write-out=json | jq -e '.ttl == -1'",
                timeout=3 * lease_ttl,
            )
            alpha.wait_until_succeeds(
                admin + "get /application/lease --write-out=json | jq -e '(.count // 0) == 0'",
                timeout=lease_ttl,
            )

        def put_watch_value(client, key, value):
            result = json.loads(proxy.succeed(client + f"put {key} {value} --write-out=json"))
            return result["header"]["revision"]

        def assert_watch_event(name, key, value, revision):
            proxy.wait_until_succeeds(
                "jq -e -s 'any(.[].Events[]?; "
                + f'(.kv.key | @base64d) == "{key}" and '
                + f'(.kv.value | @base64d) == "{value}" and .kv.mod_revision == {revision})'
                + f"' /tmp/etcd-watch-{name}.json",
                timeout=30,
            )

        def start_watch(client, name, key):
            revision = put_watch_value(client, key, "seed")
            proxy.succeed(
                f"systemd-run --unit=etcd-watch-{name} --property=Type=exec "
                "--setenv=PATH=/run/current-system/sw/bin "
                f"--property=StandardOutput=append:/tmp/etcd-watch-{name}.json "
                "env ETCDCTL_DIAL_TIMEOUT=30s "
                + client + f"watch {key} --rev={revision} --write-out=json"
            )
            proxy.wait_for_unit(f"etcd-watch-{name}.service")
            # Receiving the seed at its known revision proves the watch is ready.
            assert_watch_event(name, key, "seed", revision)

        with subtest("deliver watch events to users with separate permissions"):
            start_watch(application, "application", "/application/watch")
            start_watch(retired, "retired", "/retired/watch")
            for client, name in [(application, "application"), (retired, "retired")]:
                key = f"/{name}/watch"
                revision = put_watch_value(client, key, "updated")
                assert_watch_event(name, key, "updated", revision)

        with subtest("start a new watch after the first watch's authentication token expires"):
            # Simple tokens expire after 15 seconds idle, checked every second.
            time.sleep(17)
            start_watch(application, "refreshed", "/application/watch-after-expiry")
            for client, name, key in [
                (application, "application", "/application/watch"),
                (retired, "retired", "/retired/watch"),
                (application, "refreshed", "/application/watch-after-expiry"),
            ]:
                revision = put_watch_value(client, key, "after-expiry")
                assert_watch_event(name, key, "after-expiry", revision)
                proxy.succeed(f"systemctl stop etcd-watch-{name}.service")

        with subtest("keep the local endpoint usable when an upstream member stops"):
            alpha.shutdown()
            proxy.wait_until_succeeds(application + "put /application/proxy after-member-stop")
            assert proxy.succeed(application + "get /application/proxy --print-value-only").strip() == "after-member-stop"
      '';
    };
  };
}

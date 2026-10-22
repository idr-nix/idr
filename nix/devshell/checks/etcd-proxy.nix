top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.etcd-proxy = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./etcd-auth-fixture.nix {inherit top;})];
      name = "etcd-proxy";
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

        with subtest("keep the local endpoint usable when an upstream member stops"):
            alpha.shutdown()
            proxy.wait_until_succeeds(application + "put /application/proxy after-member-stop")
            assert proxy.succeed(application + "get /application/proxy --print-value-only").strip() == "after-member-stop"
      '';
    };
  };
}

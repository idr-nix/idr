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
        alpha.wait_until_succeeds("etcdctl --user=root:public-test-root user get application")
        proxy.wait_for_unit("idr-etcd-proxy-application.service")
        local = "env -u ETCDCTL_CACERT ETCDCTL_ENDPOINTS=http://application.etcd.internal:65535 etcdctl "
        application = local + "--user=application:public-test-application "

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

        with subtest("keep the local endpoint usable when an upstream member stops"):
            alpha.shutdown()
            proxy.wait_until_succeeds(application + "put /application/proxy after-member-stop")
            assert proxy.succeed(application + "get /application/proxy --print-value-only").strip() == "after-member-stop"
      '';
    };
  };
}

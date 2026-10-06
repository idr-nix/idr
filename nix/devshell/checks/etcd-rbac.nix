top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.etcd-rbac = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./etcd-auth-fixture.nix {inherit top;})];
      name = "etcd-rbac";
      nodes.alpha = {config, ...}: let
        updatedRBAC = [
          {
            endpoints = map (name: {domain = "etcd-${name}.example.test";}) ["alpha" "beta" "gamma"];
            caCert = ./fixtures/etcd/ca.pem;
            rootPassword = config.idr.secrets.root-password;
            roles.audit.permissions = [{target = "/status";}];
            roles.application.permissions = [
              {
                target = "/application/";
                prefix = true;
              }
            ];
            users.application = {
              password = config.idr.secrets.application-password;
              roles = ["application"];
            };
          }
        ];
      in {
        # Generation switching registers its closure in the guest store.
        virtualisation.writableStore = true;
        specialisation = {
          permissions.configuration.idr.etcd.rbac = lib.mkForce updatedRBAC;
          password.configuration = {
            idr.etcd.rbac = lib.mkForce updatedRBAC;
            idr.secrets-source.application-password.sopsFile = lib.mkForce ./fixtures/etcd/updated.enc.json;
          };
        };
      };
      testScript = ''
        import json

        start_all()
        for name, machine in [("alpha", alpha), ("beta", beta), ("gamma", gamma)]:
            machine.wait_for_unit(f"idr-etcd-{name}.service")
        admin = "etcdctl --user=root:public-test-root "
        application = "etcdctl --user=application:public-test-application "
        alpha.wait_until_succeeds(admin + "user get application")
        controller = alpha.succeed("systemctl list-units 'idr-etcd-rbac-*' --no-legend --plain | awk '{print $1}'").strip()
        assert controller.startswith("idr-etcd-rbac-")
        alpha.wait_for_unit(controller)
        alpha.succeed(application + "put /application/message initial")

        with subtest("enforce prefix, exact-key, and half-open range permissions"):
            alpha.fail("etcdctl get /application/message")
            assert alpha.succeed(application + "get /application/message --print-value-only").strip() == "initial"
            alpha.fail(application + "put /application-other denied")
            alpha.succeed(admin + "put /status healthy", admin + "put /range/a first", admin + "put /range/m middle")
            assert alpha.succeed(application + "get /status --print-value-only").strip() == "healthy"
            assert alpha.succeed(application + "get /range/a --print-value-only").strip() == "first"
            assert alpha.succeed(application + "get /range/m --print-value-only").strip() == "middle"
            alpha.fail(application + "put /status denied", application + "get /status/child")
            alpha.fail(application + "get /range/0", application + "get /range/z", application + "put /range/m denied")
            alpha.succeed(application + "put /write-only accepted")
            alpha.fail(application + "get /write-only")

        with subtest("reconcile edited permissions, removed accounts, and undeclared cluster state"):
            alpha.succeed(admin + "user add rogue --new-user-password=public-test-rogue", admin + "role add rogue")
            alpha.succeed(admin + "user grant-role rogue rogue")
            alpha.succeed("/run/current-system/specialisation/permissions/bin/switch-to-configuration test", timeout=180)
            alpha.wait_until_succeeds(admin + "user list --write-out=json | jq -e '.users == [\"application\", \"root\"]'")
            assert json.loads(alpha.succeed(admin + "role list --write-out=json"))["roles"] == ["application", "audit", "root"]
            assert json.loads(alpha.succeed(admin + "user get application --write-out=json"))["roles"] == ["application"]
            assert alpha.succeed(application + "get /application/message --print-value-only").strip() == "initial"
            alpha.fail(application + "put /application/message denied", application + "get /status")
            alpha.fail("etcdctl --user=retired:public-test-application get /retired/key")
            alpha.wait_for_unit(controller)
            old_invocation = alpha.succeed(f"systemctl show {controller} --property=InvocationID --value").strip()
            old_unit = alpha.succeed(f"systemctl show {controller} --property=FragmentPath --value").strip()
            assert old_invocation

        with subtest("reconcile a changed password through its secret restart target"):
            alpha.succeed("/run/booted-system/specialisation/password/bin/switch-to-configuration test", timeout=180)
            new_application = "etcdctl --user=application:public-test-updated "
            alpha.wait_until_succeeds(new_application + "get /application/message")
            alpha.wait_for_unit(controller)
            assert alpha.succeed(new_application + "get /application/message --print-value-only").strip() == "initial"
            alpha.fail(application + "get /application/message")
            # Only the source secret changed; the RBAC controller unit is identical.
            assert alpha.succeed(f"systemctl show {controller} --property=FragmentPath --value").strip() == old_unit
            assert alpha.succeed(f"systemctl show {controller} --property=InvocationID --value").strip() != old_invocation
            assert json.loads(alpha.succeed(admin + "user get root --write-out=json"))["roles"] == ["root"]
      '';
    };
  };
}

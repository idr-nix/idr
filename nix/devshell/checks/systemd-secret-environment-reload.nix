top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.systemd-secret-environment-reload = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./systemd-secret-environment-fixture.nix {
          inherit top;
          useVM = true;
        })
      ];

      name = "systemd-secret-environment-reload";

      defaults.specialisation.updated.configuration.idr.secrets-source.api-token.sopsFile =
        lib.mkForce ./fixtures/runtime-secrets/updated.enc.json;

      testScript = ''
        start_all()
        machine.wait_for_unit("my-app.service")
        machine.wait_until_succeeds("test -s /run/my-app/startup-token.sha256")

        def token_hash():
            return machine.succeed(
                "bash -ec 'value=$(cat /run/secrets/api-token); "
                "printf %s \"$value\" | sha256sum'"
            ).split()[0]

        original_hash = token_hash()
        assert machine.succeed("cat /run/my-app/startup-token.sha256").split()[0] == original_hash
        original_pid = machine.succeed("systemctl show my-app -p MainPID --value").strip()
        assert original_pid != "0"
        machine.fail("test -e /run/my-app/reloaded-token.sha256")

        with subtest("default to reload when the service defines a reload command"):
            machine.succeed(
                "/run/current-system/specialisation/updated/bin/switch-to-configuration test",
                timeout=180,
            )
            machine.wait_for_unit("my-app.service")
            updated_hash = token_hash()
            assert updated_hash != original_hash
            machine.wait_until_succeeds(
                "test \"$(cut -d ' ' -f 1 /run/my-app/reloaded-token.sha256)\" = " + updated_hash,
                timeout=60,
            )
            assert machine.succeed("systemctl show my-app -p MainPID --value").strip() == original_pid
            assert machine.succeed("cat /run/my-app/startup-token.sha256").split()[0] == original_hash
      '';
    };

    checks.systemd-secret-environment-failure = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./systemd-secret-environment-fixture.nix {
          inherit top;
          # No generation switching is needed; Darwin retains a Linux VM guest.
          useVM = pkgs.stdenv.hostPlatform.isDarwin;
        })
      ];

      name = "systemd-secret-environment-failure";
      defaults.idr.secrets-source.my-app-env.exec = lib.mkForce "exit 1";

      testScript = ''
        start_all()
        with subtest("refuse service startup when its secret environment cannot be generated"):
            machine.wait_until_succeeds("systemctl is-failed idr-secrets.service")
            machine.fail("systemctl start my-app.service")
            machine.fail("test -e /run/my-app/startup-token.sha256")
            machine.fail("test -e /run/idr-secrets/my-app-env")
      '';
    };
  };
}

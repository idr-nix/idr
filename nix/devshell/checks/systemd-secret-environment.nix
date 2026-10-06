top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.systemd-secret-environment = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./runtime-secrets-fixture.nix {
          inherit top;
          # Generation switching is not supported by the nspawn test harness.
          useVM = true;
        })
      ];

      name = "systemd-secret-environment";

      defaults = {
        config,
        pkgs,
        ...
      }: {
        idr.systemd.services.my-app = {
          environment = {
            API_URL = "https://example.com";
            API_TOKEN = config.idr.secrets.api-token;
            WORKERS = 4;
            DEBUG = false;
          };
          reloadOnEnvironmentChange = false;
        };
        systemd.services.my-app = {
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            User = "my-app";
            Group = "my-app";
            RuntimeDirectory = "my-app";
          };
          path = [pkgs.coreutils];
          script = ''
            printf '%s' "$API_TOKEN" | sha256sum > /run/my-app/token.sha256
            printf '%s\n' "$API_URL" "$WORKERS" "$DEBUG" > /run/my-app/settings
            exec sleep infinity
          '';
        };
        specialisation.updated.configuration.idr.secrets-source.api-token.sopsFile =
          lib.mkForce ./fixtures/runtime-secrets/updated.enc.json;
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("my-app.service")
        machine.wait_until_succeeds("test -s /run/my-app/settings")

        def token_hash():
            return machine.succeed(
                "bash -ec 'value=$(cat /run/secrets/api-token); "
                "printf %s \"$value\" | sha256sum'"
            ).split()[0]

        with subtest("provide typed settings and trim trailing newlines from the secret"):
            assert machine.succeed("cat /run/my-app/settings").splitlines() == [
                "https://example.com", "4", "false",
            ]
            original_hash = token_hash()
            assert machine.succeed("cat /run/my-app/token.sha256").split()[0] == original_hash
            environment = machine.succeed("systemctl show my-app -p Environment --value")
            assert "API_TOKEN=" not in environment
            original_pid = machine.succeed("systemctl show my-app -p MainPID --value").strip()
            assert original_pid != "0"

        with subtest("apply changed encrypted data and restart to receive the new environment"):
            machine.succeed(
                "/run/current-system/specialisation/updated/bin/switch-to-configuration test",
                timeout=180,
            )
            machine.wait_for_unit("my-app.service")
            updated_hash = token_hash()
            assert updated_hash != original_hash
            machine.wait_until_succeeds(
                "test \"$(cut -d ' ' -f 1 /run/my-app/token.sha256)\" = " + updated_hash
            )
            updated_pid = machine.succeed("systemctl show my-app -p MainPID --value").strip()
            assert updated_pid != "0" and updated_pid != original_pid
      '';
    };
  };
}

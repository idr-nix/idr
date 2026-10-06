top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.runtime-secrets-environment = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./runtime-secrets-fixture.nix {
          inherit top;
          useVM = true;
        })
      ];

      name = "runtime-secrets-environment";

      defaults = {
        config,
        pkgs,
        ...
      }: {
        idr.secrets-source.app-env.secrets.API_TOKEN = config.idr.secrets.api-token;
        systemd.services.my-app = let
          secret = config.idr.secrets.app-env;
        in {
          wantedBy = ["multi-user.target"];
          wants = [secret.restartTarget];
          after = [secret.restartTarget];
          partOf = [secret.restartTarget];
          serviceConfig = {
            EnvironmentFile = secret.path;
            User = "my-app";
            Group = "my-app";
            RuntimeDirectory = "my-app";
          };
          path = [pkgs.coreutils];
          script = ''
            printf '%s' "$API_TOKEN" | sha256sum > /run/my-app/token.sha256
            exec sleep infinity
          '';
        };
        specialisation.updated.configuration.idr.secrets-source.api-token.sopsFile =
          lib.mkForce ./fixtures/runtime-secrets/updated.enc.json;
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("my-app.service")
        machine.wait_until_succeeds("test -s /run/my-app/token.sha256")

        with subtest("generate an EnvironmentFile and preserve the secret's quoting and newlines"):
            original_hash = machine.succeed("sha256sum < /run/secrets/api-token").split()[0]
            assert machine.succeed("cat /run/my-app/token.sha256").split()[0] == original_hash
            original_pid = machine.succeed("systemctl show my-app -p MainPID --value").strip()
            assert original_pid != "0"
            environment = machine.succeed("systemctl show my-app -p Environment --value")
            assert "API_TOKEN=" not in environment

        with subtest("deploy changed encrypted data and restart the service with its new environment"):
            machine.succeed(
                "/run/current-system/specialisation/updated/bin/switch-to-configuration test",
                timeout=180,
            )
            machine.wait_for_unit("my-app.service")
            updated_hash = machine.succeed("sha256sum < /run/secrets/api-token").split()[0]
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

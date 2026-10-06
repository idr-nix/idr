top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.runtime-secrets-reload = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./runtime-secrets-fixture.nix {
          inherit top;
          # Generation switching is not supported by the nspawn test harness.
          useVM = true;
        })
      ];

      name = "runtime-secrets-reload";

      defaults = {
        config,
        pkgs,
        ...
      }: {
        idr.secrets-source.auth-header = {
          secrets.TOKEN = config.idr.secrets.api-token;
          template = "Authorization: Bearer $TOKEN";
        };
        systemd.services.my-app = let
          secret = config.idr.secrets.auth-header;
          app = pkgs.writers.writePython3 "my-app" {} ''
            import hashlib
            import pathlib
            import signal


            def reload_config(*_args):
                secret_file = pathlib.Path("${secret.path}")
                digest = hashlib.sha256(secret_file.read_bytes())
                temporary = pathlib.Path("/run/my-app/token.sha256.tmp")
                temporary.write_text(digest.hexdigest())
                temporary.replace("/run/my-app/token.sha256")


            signal.signal(signal.SIGHUP, reload_config)
            reload_config()
            while True:
                signal.pause()
          '';
        in {
          wantedBy = ["multi-user.target"];
          wants = [secret.reloadTarget];
          after = [secret.reloadTarget];
          partOf = [secret.reloadTarget];
          unitConfig.ReloadPropagatedFrom = [secret.reloadTarget];
          serviceConfig = {
            User = "my-app";
            Group = "my-app";
            SupplementaryGroups = [secret.group];
            RuntimeDirectory = "my-app";
            ExecStart = app;
            ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
          };
        };
        specialisation.updated.configuration.idr.secrets-source.api-token.sopsFile =
          lib.mkForce ./fixtures/runtime-secrets/updated.enc.json;
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("my-app.service")
        machine.wait_until_succeeds("test -s /run/my-app/token.sha256")

        with subtest("read a generated secret through the service's supplementary group"):
            original_hash = machine.succeed("sha256sum < /run/idr-secrets/auth-header").split()[0]
            assert machine.succeed("cat /run/my-app/token.sha256").strip() == original_hash
            original_pid = machine.succeed("systemctl show my-app -p MainPID --value").strip()
            assert original_pid != "0"

        with subtest("apply a changed secret and propagate reload without restarting the application"):
            machine.succeed(
                "/run/current-system/specialisation/updated/bin/switch-to-configuration test",
                timeout=180,
            )
            machine.wait_for_unit("my-app.service")
            updated_hash = machine.succeed("sha256sum < /run/idr-secrets/auth-header").split()[0]
            assert updated_hash != original_hash
            machine.wait_until_succeeds(
                "test \"$(cat /run/my-app/token.sha256)\" = " + updated_hash
            )
            assert machine.succeed("systemctl show my-app -p MainPID --value").strip() == original_pid
      '';
    };
  };
}

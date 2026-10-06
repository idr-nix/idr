top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.runtime-secrets-manual-refresh = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./runtime-secrets-fixture.nix {
          inherit top;
          useVM = true;
        })
      ];

      name = "runtime-secrets-manual-refresh";

      defaults = {
        config,
        pkgs,
        ...
      }: {
        idr.secrets-source = {
          auth-header = {
            secrets.TOKEN = config.idr.secrets.api-token;
            template = "Authorization: Bearer $TOKEN";
          };
          app-config = {
            secrets.HEADER = config.idr.secrets.auth-header;
            exec = ''
              ${pkgs.jq}/bin/jq -n '{authorization: env.HEADER}'
            '';
          };
        };
        systemd.services.my-app = let
          secret = config.idr.secrets.app-config;
          app = pkgs.writers.writePython3 "my-app" {} ''
            import hashlib
            import pathlib
            import signal


            def reload_config(*_args):
                content = pathlib.Path("${secret.path}").read_bytes()
                temporary = pathlib.Path("/run/my-app/config.sha256.tmp")
                temporary.write_text(hashlib.sha256(content).hexdigest())
                temporary.replace("/run/my-app/config.sha256")


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
        specialisation = {
          template-updated.configuration.idr.secrets-source.auth-header.template =
            lib.mkForce "X-API-Token: $TOKEN";
          generator-updated.configuration.idr.secrets-source = {
            auth-header.template = lib.mkForce "X-API-Token: $TOKEN";
            app-config.exec = lib.mkForce ''
              ${pkgs.jq}/bin/jq -n '{authorization: env.HEADER, version: 2}'
            '';
          };
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("my-app.service")
        machine.wait_until_succeeds("test -s /run/my-app/config.sha256")

        template_system = machine.succeed(
            "readlink -f /run/current-system/specialisation/template-updated"
        ).strip()
        generator_system = machine.succeed(
            "readlink -f /run/current-system/specialisation/generator-updated"
        ).strip()
        original_token_hash = machine.succeed("sha256sum < /run/secrets/api-token").split()[0]
        original_config_hash = machine.succeed("sha256sum < /run/idr-secrets/app-config").split()[0]
        assert machine.succeed("cat /run/my-app/config.sha256").strip() == original_config_hash
        original_pid = machine.succeed("systemctl show my-app -p MainPID --value").strip()
        assert original_pid != "0"

        with subtest("deploy a template-only change and reload the application manually"):
            machine.succeed(template_system + "/bin/switch-to-configuration test", timeout=180)
            machine.wait_until_succeeds('test -z "$(systemctl list-jobs --no-legend)"')
            template_hash = machine.succeed("sha256sum < /run/idr-secrets/app-config").split()[0]
            assert template_hash != original_config_hash
            assert machine.succeed("sha256sum < /run/secrets/api-token").split()[0] == original_token_hash
            assert machine.succeed("cat /run/my-app/config.sha256").strip() == original_config_hash
            assert machine.succeed("systemctl show my-app -p MainPID --value").strip() == original_pid

            machine.succeed("systemctl reload my-app")
            machine.wait_until_succeeds(
                "test \"$(cat /run/my-app/config.sha256)\" = " + template_hash
            )
            assert machine.succeed("systemctl show my-app -p MainPID --value").strip() == original_pid

        with subtest("deploy a generator change and restart the application manually"):
            machine.succeed(generator_system + "/bin/switch-to-configuration test", timeout=180)
            machine.wait_until_succeeds('test -z "$(systemctl list-jobs --no-legend)"')
            generator_hash = machine.succeed("sha256sum < /run/idr-secrets/app-config").split()[0]
            assert generator_hash not in [original_config_hash, template_hash]
            assert machine.succeed("sha256sum < /run/secrets/api-token").split()[0] == original_token_hash
            assert machine.succeed("cat /run/my-app/config.sha256").strip() == template_hash
            assert machine.succeed("systemctl show my-app -p MainPID --value").strip() == original_pid

            machine.succeed("systemctl restart my-app")
            machine.wait_for_unit("my-app.service")
            machine.wait_until_succeeds(
                "test \"$(cat /run/my-app/config.sha256)\" = " + generator_hash
            )
            updated_pid = machine.succeed("systemctl show my-app -p MainPID --value").strip()
            assert updated_pid != "0" and updated_pid != original_pid
      '';
    };
  };
}

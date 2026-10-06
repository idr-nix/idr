top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.runtime-secrets-files = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./runtime-secrets-fixture.nix {
          inherit top;
          useVM = !pkgs.stdenv.hostPlatform.isLinux;
        })
      ];

      name = "runtime-secrets-files";

      defaults = {
        config,
        pkgs,
        ...
      }: {
        environment.systemPackages = [pkgs.jq];
        idr.secrets-source = {
          auth-header = {
            secrets.TOKEN = config.idr.secrets.api-token;
            template = "Authorization: Bearer $TOKEN; $UNDECLARED";
          };
          app-config = {
            secrets.TOKEN = config.idr.secrets.api-token;
            exec = "${pkgs.writers.writeNu "app-config" ''
              {token: $env.TOKEN} | to json
            ''}";
          };
          output-file = {
            secrets.HEADER = config.idr.secrets.auth-header;
            exec = ''
              printf '%s' "$HEADER" > "$out"
              printf 'stdout is ignored when the generator writes to $out'
            '';
          };
        };

        systemd.services.my-app = let
          secret = config.idr.secrets.app-config;
        in {
          wantedBy = ["multi-user.target"];
          wants = [secret.restartTarget];
          after = [secret.restartTarget];
          partOf = [secret.restartTarget];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "my-app";
            Group = "my-app";
            SupplementaryGroups = [secret.group];
            RuntimeDirectory = "my-app";
          };
          path = [pkgs.jq pkgs.coreutils];
          script = ''
            jq -jr .token ${secret.path} | sha256sum > /run/my-app/token.sha256
          '';
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("my-app.service")

        with subtest("read a SOPS source and a generated JSON file as the application user"):
            token_hash = machine.succeed("sha256sum < /run/secrets/api-token").split()[0]
            assert token_hash == "c841d8abfb5c205cd4db6da8926ad7555646e11538d9d58fa7e46c80b0fc3731"
            app_hash = machine.succeed("cat /run/my-app/token.sha256").split()[0]
            assert app_hash == token_hash

        with subtest("substitute declared variables and let the output file take precedence"):
            machine.succeed(
                "(printf '%s' 'Authorization: Bearer '; cat /run/secrets/api-token; "
                "printf '%s' '; $UNDECLARED') | cmp - /run/idr-secrets/auth-header"
            )
            machine.succeed("cmp /run/idr-secrets/auth-header /run/idr-secrets/output-file")

        with subtest("restrict each file to root and its declared secret group"):
            assert machine.succeed("su -s /bin/sh untrusted -c 'id -un'").strip() == "untrusted"
            secret_groups = set()
            for path in [
                "/run/secrets/api-token",
                "/run/idr-secrets/auth-header",
                "/run/idr-secrets/app-config",
                "/run/idr-secrets/output-file",
            ]:
                owner, group, mode = machine.succeed(f"stat -Lc '%U %g %a' {path}").split()
                assert owner == "root" and mode == "440"
                assert group not in secret_groups
                secret_groups.add(group)
                machine.fail(f"su -s /bin/sh untrusted -c 'cat {path} >/dev/null'")
            machine.fail("su -s /bin/sh my-app -c 'cat /run/secrets/api-token >/dev/null'")
      '';
    };
  };
}

top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.preset-container-secrets = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./preset-container-fixture.nix {inherit top;})
      ];

      name = "preset-container-secrets";

      nodes.machine = {config, ...}: {
        # Deliberately public test key; the container receives the normal read-only mount.
        environment.etc."ssh/test-container-host-key" = {
          source = ./fixtures/preset-container/ssh_host_ed25519_key;
          mode = "0400";
        };
        sops = {
          age.sshKeyPaths = lib.mkForce ["/etc/ssh/test-container-host-key"];
          gnupg.sshKeyPaths = [];
          useSystemdActivation = true;
          secrets.api-token.format = "json";
        };
        idr.secrets-source = {
          api-token = {
            sopsFile = ./fixtures/preset-container/initial.enc.json;
            key = "api_token";
          };
          auth-header = {
            secrets.TOKEN = config.idr.secrets.api-token;
            template = "Authorization: Bearer $TOKEN";
          };
        };

        containers.example.config = {
          config,
          pkgs,
          ...
        }: {
          sops.useSystemdActivation = true;
          users.users.my-app = {
            isSystemUser = true;
            group = "my-app";
          };
          users.groups.my-app = {};
          idr.systemd.services.my-app = {
            environment.AUTH_HEADER = config.idr.secrets.auth-header;
            reloadOnEnvironmentChange = false;
          };
          systemd.services.my-app = {
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              User = "my-app";
              Group = "my-app";
              RuntimeDirectory = "my-app";
              ExecStart = pkgs.writers.writePython3 "container-app" {} ''
                import hashlib
                import os
                import pathlib
                import signal

                digest = hashlib.sha256(os.environ["AUTH_HEADER"].encode()).hexdigest()
                pathlib.Path("/run/my-app/header.sha256").write_text(digest)
                while True:
                    signal.pause()
              '';
            };
          };
        };

        specialisation.updated.configuration.idr.secrets-source.api-token.sopsFile =
          lib.mkForce ./fixtures/preset-container/updated.enc.json;
      };

      testScript = ''
        import hashlib

        start_all()
        machine.wait_for_unit("container@example.service")
        container = "nixos-container run example -- "
        machine.wait_until_succeeds(container + "systemctl is-active my-app.service")
        machine.wait_until_succeeds(container + "test -s /run/my-app/header.sha256")

        with subtest("inherit host SOPS sources and generated service environment inside the container"):
            initial_hash = hashlib.sha256(b"Authorization: Bearer container-first-value").hexdigest()
            assert machine.succeed(container + "cat /run/my-app/header.sha256").strip() == initial_hash
            assert machine.succeed(container + "sha256sum /run/idr-secrets/auth-header").split()[0] == initial_hash
            assert machine.succeed("sha256sum /run/idr-secrets/auth-header").split()[0] == initial_hash
            mount_options = machine.succeed(
                container + "findmnt -n -o OPTIONS /etc/ssh/test-container-host-key"
            ).strip().split(",")
            assert "ro" in mount_options
            leader = machine.succeed("machinectl show example -p Leader --value").strip()
            application_pid = machine.succeed(container + "systemctl show my-app -p MainPID --value").strip()
            assert leader not in ["", "0"] and application_pid not in ["", "0"]

        with subtest("deploy a changed host secret without restarting the container"):
            machine.succeed(
                "/run/current-system/specialisation/updated/bin/switch-to-configuration test",
                timeout=300,
            )
            updated_hash = hashlib.sha256(b"Authorization: Bearer container-updated-value").hexdigest()
            machine.wait_until_succeeds(
                "test \"$(" + container + "cat /run/my-app/header.sha256)\" = " + updated_hash,
                timeout=180,
            )
            assert machine.succeed("sha256sum /run/idr-secrets/auth-header").split()[0] == updated_hash
            assert machine.succeed("machinectl show example -p Leader --value").strip() == leader
            updated_pid = machine.succeed(container + "systemctl show my-app -p MainPID --value").strip()
            assert updated_pid not in ["", "0", application_pid]
      '';
    };
  };
}

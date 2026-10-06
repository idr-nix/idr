top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    sourceKey = lib.trim (builtins.readFile ./fixtures/backup/source_rotated_ed25519.pub);
    serverKey = lib.trim (builtins.readFile ./fixtures/backup/server_rotated_ed25519.pub);
    rotatedSource = {
      test.backup = {
        hostKeyPath = "/etc/ssh/source-rotated-key";
        hostPublicKey = sourceKey;
      };
    };
    payload = text: snapshot: {
      systemd.services.test-payload = {
        wantedBy = ["multi-user.target"];
        after = ["test-data-disk.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          printf '%s\n' ${lib.escapeShellArg text} > /srv/application/message
          /run/booted-system/sw/bin/zfs snapshot -r p1@${snapshot}
        '';
      };
    };
  in {
    checks.backup-host-key-rotation = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./fixtures/backup-pair.nix {inherit top pkgs;})];
      name = "backup-host-key-rotation";

      nodes = {
        source.specialisation = {
          source-key.configuration = lib.mkMerge [
            rotatedSource
            (payload "data after source key rotation" "source-key-updated")
          ];
          team-key.configuration = lib.mkMerge [
            rotatedSource
            {test.backup.authorizedPublicKey = serverKey;}
            (payload "data after backup team key rotation" "team-key-updated")
          ];
        };
        server = {nodes, ...}: let
          updatedMetadata = nodes.source.specialisation.source-key.configuration.system.build.idr.meta;
        in {
          specialisation = {
            source-metadata.configuration.test.backup.sourceMetadata = updatedMetadata;
            backup-key.configuration.test.backup = {
              sourceMetadata = updatedMetadata;
              hostKeyPath = "/etc/ssh/server-rotated-key";
            };
          };
        };
      };

      testScript = ''
        start_all()
        source.wait_for_unit("idr-backup-access.service")
        source.wait_for_unit("sshd.service")
        server.wait_for_unit("idr-backup-prepare.service")
        source_system = source.succeed("readlink -f /run/current-system").strip()
        server_system = server.succeed("readlink -f /run/current-system").strip()
        unit = "idr-backup-source-bac000000001.service"
        dataset = "p1/backups/source-bac000000001/p1/application"

        with subtest("take a backup using the current team identity and host-key pin"):
            server.succeed("systemctl start " + unit, timeout=300)
            server.succeed("zfs list " + dataset + "@test-initial")

        with subtest("source key rotation requires deploying its updated metadata to the backup server"):
            source.succeed(source_system + "/specialisation/source-key/bin/switch-to-configuration test", timeout=180)
            source.wait_for_unit("sshd.service")
            source.wait_for_unit("test-payload.service")
            server.fail("systemctl start " + unit, timeout=120)
            assert "Host key verification failed" in server.succeed("journalctl -u " + unit + " -I --no-pager")
            server.succeed(server_system + "/specialisation/source-metadata/bin/switch-to-configuration test", timeout=180)
            server.succeed("systemctl start " + unit, timeout=300)
            server.succeed("zfs list " + dataset + "@source-key-updated")

        with subtest("backup identity rotation requires updating the source's backup-server team member"):
            server.succeed(server_system + "/specialisation/backup-key/bin/switch-to-configuration test", timeout=180)
            server.fail("systemctl start " + unit, timeout=120)
            assert "Permission denied (publickey)" in server.succeed("journalctl -u " + unit + " -I --no-pager")
            source.succeed(source_system + "/specialisation/team-key/bin/switch-to-configuration test", timeout=180)
            source.wait_for_unit("sshd.service")
            source.wait_for_unit("test-payload.service")
            server.succeed("systemctl start " + unit, timeout=300)
            server.succeed("zfs list " + dataset + "@team-key-updated")

        with subtest("the former backup identity is denied after deploying the team update"):
            server.succeed(server_system + "/specialisation/source-metadata/bin/switch-to-configuration test", timeout=180)
            server.fail("systemctl start " + unit, timeout=120)
            assert "Permission denied (publickey)" in server.succeed("journalctl -u " + unit + " -I --no-pager")
            server.succeed(server_system + "/specialisation/backup-key/bin/switch-to-configuration test", timeout=180)
            server.succeed("systemctl start " + unit, timeout=300)
            server.succeed("zfs set mountpoint=legacy " + dataset)
            server.succeed("mount -t zfs -o ro " + dataset + " /mnt/backup")
            assert server.succeed("cat /mnt/backup/message").strip() == "data after backup team key rotation"
            server.succeed("umount /mnt/backup")
      '';
    };
  };
}

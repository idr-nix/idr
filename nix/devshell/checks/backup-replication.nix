top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    # Nixpkgs publishes these identities solely for tests.
    keys = import "${top.inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs;
    backupTop =
      top
      // {
        idr-lib =
          top.idr-lib
          // {
            team.backup-machine-bac000000002 = {
              system = true;
              groups = ["backup-server"];
              sshPublicKey = keys.snakeOilEd25519PublicKey;
            };
          };
      };
    sourcePublicKey = lib.trim (builtins.readFile ./fixtures/backup/source_ed25519.pub);
    sourceId = "bac000000001";
    serverId = "bac000000002";
    sourceSecrets = builtins.toFile "backup-source-public-metadata.json" (builtins.toJSON {
      ssh_host_ed25519_key_pub_unencrypted = sourcePublicKey;
    });
  in {
    checks = {
      backup-replication = pkgs.testers.runNixOSTest {
        name = "backup-replication";
        node.pkgsReadOnly = false;
        globalTimeout = 15 * 60;

        defaults = {lib, ...}: {
          imports = [(lib.modules.importApply ./fixtures/backup-machine.nix backupTop)];
          services.openssh.hostKeys = lib.mkForce [
            {
              type = "ed25519";
              path = "/etc/ssh/ssh_host_ed25519_key";
            }
          ];
          systemd.services.sshd-keygen.after = ["systemd-tmpfiles-setup.service"];
        };

        nodes = {
          source = {
            systemd.tmpfiles.rules = [
              "C /etc/ssh/ssh_host_ed25519_key 0600 root root - ${./fixtures/backup/source_ed25519}"
            ];
            idr.preset.base = {
              id = sourceId;
              defaultSopsFile = sourceSecrets;
            };
            services.openssh.ports = [2222];
            disko.devices.zpool.p1.datasets = {
              application = {
                type = "zfs_fs";
                mountpoint = "/srv/application";
              };
              cache = {
                type = "zfs_fs";
                options = {
                  mountpoint = "none";
                  "syncoid:sync" = "false";
                };
              };
              "cache/child" = {
                type = "zfs_fs";
                options.mountpoint = "none";
              };
            };
            systemd.services.test-data-disk.postStart = ''
              /run/booted-system/sw/bin/zfs mount p1/application
              printf 'application data\n' > /srv/application/message
              current_time=$(date +%s)
              trap 'date -s "@$current_time" >/dev/null' EXIT
              date -s "@$((current_time - 7200))" >/dev/null
              /run/booted-system/sw/bin/zfs snapshot "p1/application@autosnap_$(date -u +%Y-%m-%d_%H:%M:%S)_hourly"
            '';
          };
          server = {nodes, ...}: let
            # Use the source's real published metadata in the same shape as a
            # deploy-rs system profile. Port 2222 also exercises its SSH options.
            productionNode = {
              hostname = "source";
              sshOpts = ["-p" "2222"];
              profiles.system.path.idr = {
                meta = nodes.source.system.build.idr.meta;
                globalSshOpts = [];
              };
            };
          in {
            idr.preset.base.id = serverId;
            idr.backup.client.enable = false;
            idr.backup.server = {
              enable = true;
              dataset = "p1/backups";
              interval = "2099-01-01 00:00:00";
              nodes = [
                productionNode
                (lib.recursiveUpdate productionNode {
                  profiles.system.path.idr = {
                    qemuProcess = "vm-source";
                    meta.machine = "vm-source";
                  };
                })
                (lib.recursiveUpdate productionNode {
                  profiles.system.path.idr.meta = {
                    machine = "server";
                    machineId = serverId;
                  };
                })
              ];
            };
            # Snapshot creation is disabled for received data by the backup
            # module. Retain just one hourly generation for this example.
            services.sanoid.templates.idr_long_term = {
              yearly = 0;
              monthly = 0;
              weekly = 0;
              daily = 0;
              hourly = 1;
              frequently = 0;
            };
            programs.ssh.extraConfig = ''
              Host source
                User idr-backup
                Port 2222
                IdentityFile /etc/ssh/ssh_host_ed25519_key
                IdentitiesOnly yes
                BatchMode yes
            '';
            programs.ssh.knownHosts.source.publicKey = sourcePublicKey;
            systemd.tmpfiles.rules = [
              "C /etc/ssh/ssh_host_ed25519_key 0600 root root - ${keys.snakeOilEd25519PrivateKey}"
              "C /root/unauthorized-key 0600 root root - ${keys.snakeOilPrivateKey}"
              "d /mnt/backup 0755 root root -"
            ];
          };
        };

        testScript = ''
          start_all()
          source.wait_for_unit("idr-backup-access.service")
          source.wait_for_unit("sshd.service")
          server.wait_for_unit("idr-backup-prepare.service")
          source.wait_for_open_port(2222)
          server.fail("getent passwd idr-backup")
          destination = "p1/backups/source-${sourceId}/p1"
          unit = "idr-backup-source-${sourceId}.service"

          with subtest("pull snapshots immediately using the backup server host identity"):
              source.succeed("systemctl start --wait sanoid.service")
              source_snapshots = source.succeed("zfs list -H -t snapshot -o name p1/application").splitlines()
              assert source_snapshots, source_snapshots
              server.succeed("systemctl start " + unit, timeout=300)
              assert server.succeed("systemctl --failed --no-legend --no-pager").strip() == ""
              received = server.succeed("zfs list -H -t snapshot -o name " + destination + "/application").splitlines()
              expected_received = [
                  name.replace("p1/application", destination + "/application", 1)
                  for name in source_snapshots
              ]
              assert received == expected_received, (received, expected_received)
              assert server.succeed("zfs get -H -o value readonly " + destination + "/application").strip() == "on"
              assert server.succeed("zfs get -H -o value mounted " + destination + "/application").strip() == "no"
              assert server.succeed("zfs get -H -o value syncoid:sync p1/backups").strip() == "false"
              server.fail("zfs list " + destination + "/cache")
              server.fail("zfs list " + destination + "/cache/child")
              assert server.succeed("systemctl list-unit-files 'idr-backup-*.timer' --no-legend --no-pager").count(".timer") == 1

          with subtest("read the received data without making the backup writable"):
              server.succeed("zfs set mountpoint=legacy " + destination + "/application")
              server.succeed("mount -t zfs -o ro " + destination + "/application /mnt/backup")
              assert server.succeed("cat /mnt/backup/message").strip() == "application data"
              server.fail("touch /mnt/backup/should-not-exist")
              server.succeed("umount /mnt/backup")

          with subtest("the delegated account can send and hold but cannot modify the source"):
              snapshot = source_snapshots[0]
              server.succeed("ssh -n source zfs hold test-backup " + snapshot)
              assert "test-backup" in source.succeed("zfs holds " + snapshot)
              # Use the newest, unheld snapshot: a hold or a newer snapshot
              # must not be the reason these destructive operations fail.
              latest = source.succeed(
                  "zfs list -H -t snapshot -o name -s createtxg p1/application"
              ).splitlines()[-1]
              assert latest != snapshot
              for command in [
                  "zfs snapshot p1/application@not-authorized",
                  "zfs destroy " + latest,
                  "zfs rollback " + latest,
                  "zfs create p1/not-authorized",
              ]:
                  status, output = server.execute("ssh -n source " + command + " 2>&1")
                  assert status != 0 and "permission denied" in output.lower(), output
              server.fail("ssh -n source sudo -n true")
              status, output = server.execute(
                  "ssh -n -F /dev/null -p 2222 -o BatchMode=yes -o IdentitiesOnly=yes "
                  "-i /root/unauthorized-key idr-backup@source true 2>&1"
              )
              assert status != 0 and "Permission denied (publickey)" in output, output

          with subtest("repeating the backup preserves snapshots and creates no sync snapshots"):
              server.succeed("systemctl start " + unit, timeout=300)
              assert source.succeed("zfs list -H -t snapshot -o name p1/application").splitlines() == source_snapshots
              assert server.succeed("zfs list -H -t snapshot -o name " + destination + "/application").splitlines() == received

          with subtest("the destination applies its own long-term retention without creating snapshots"):
              server.succeed("systemctl start --wait sanoid.service")
              retained = server.succeed("zfs list -H -t snapshot -o name " + destination + "/application").splitlines()
              assert len(retained) == 1 and retained[0].endswith("_hourly"), retained
              assert retained[0] in received, retained
              assert source.succeed("zfs list -H -t snapshot -o name p1/application").splitlines() == source_snapshots
        '';
      };
    };
  };
}

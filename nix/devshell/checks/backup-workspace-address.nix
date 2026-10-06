top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    prefix = "fd42:8844:1234";
    workspace = "12ab34cd";
    sourceAddress = "${prefix}:12ab:34cd:bac0:0000:0001";
    serverAddress = "${prefix}:12ab:34cd:bac0:0000:0002";
  in {
    checks.backup-workspace-address = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./fixtures/backup-pair.nix {inherit top pkgs;})];
      name = "backup-workspace-address";

      defaults = {
        idr.qemu.networkPrefix = prefix;
        # These go through QEMU fw_cfg and systemd's real credential importer.
        virtualisation.credentials = {
          "idr.workspace-id" = {
            mechanism = "fw_cfg";
            text = workspace;
          };
          "idr.network-prefix-length" = {
            mechanism = "fw_cfg";
            text = "80";
          };
        };
      };
      nodes = {
        source.networking.interfaces.eth1.ipv6.addresses = [
          {
            address = sourceAddress;
            prefixLength = 80;
          }
        ];
        server = {
          networking.interfaces.eth1.ipv6.addresses = [
            {
              address = serverAddress;
              prefixLength = 80;
            }
          ];
          # Local QEMU backups must use the workspace address and metadata port,
          # ignoring production addressing and SSH routing completely.
          test.backup = {
            hostname = "production-unreachable.invalid";
            sshOptions = ["-p" "1" "-o" "ProxyCommand=false"];
          };
        };
      };

      testScript = ''
        start_all()
        source.wait_for_unit("idr-backup-access.service")
        source.wait_for_unit("sshd.service")
        server.wait_for_unit("idr-backup-prepare.service")
        server.wait_until_succeeds("ping -6 -c 1 -W 1 ${sourceAddress}")

        with subtest("pull from this QEMU workspace using its configured SSH port"):
            server.succeed("systemctl start idr-backup-source-bac000000001.service", timeout=300)
            dataset = "p1/backups/source-bac000000001/p1/application"
            assert server.succeed("zfs list -H -t snapshot -o name " + dataset).strip() == dataset + "@test-initial"
            assert server.succeed("zfs get -H -o value readonly " + dataset).strip() == "on"
            server.succeed("zfs set mountpoint=legacy " + dataset)
            server.succeed("mount -t zfs -o ro " + dataset + " /mnt/backup")
            assert server.succeed("cat /mnt/backup/message").strip() == "initial application data"
            server.succeed("umount /mnt/backup")
      '';
    };
  };
}

top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks = {
      backup-local-snapshots = pkgs.testers.runNixOSTest {
        name = "backup-local-snapshots";
        node.pkgsReadOnly = false;
        globalTimeout = 10 * 60;

        nodes.machine = {
          imports = [(lib.modules.importApply ./fixtures/backup-machine.nix top)];
          idr.preset.base.id = "bac000000001";
          disko.devices.zpool.p1.datasets = {
            application = {
              type = "zfs_fs";
              options.mountpoint = "none";
            };
            cache = {
              type = "zfs_fs";
              options = {
                mountpoint = "none";
                "idr:snapshots" = "false";
              };
            };
            "cache/child" = {
              type = "zfs_fs";
              options.mountpoint = "none";
            };
          };
          services.sanoid.templates.idr_short_term = {
            yearly = 0;
            monthly = 0;
            weekly = 0;
            daily = 0;
            hourly = 1;
            frequently = 0;
          };
          systemd.services.test-data-disk.postStart = ''
            # Existing snapshots predate the policy deployment. Both must survive
            # on excluded datasets, while ordinary data follows its retention.
            current_time=$(date +%s)
            trap 'date -s "@$current_time" >/dev/null' EXIT
            date -s '2000-01-01 00:00:00 UTC' >/dev/null
            for dataset in p1/application p1/cache p1/cache/child; do
              /run/booted-system/sw/bin/zfs snapshot "$dataset@autosnap_2000-01-01_00:00:00_hourly"
              /run/booted-system/sw/bin/zfs snapshot "$dataset@autosnap_2000-01-01_01:00:00_hourly"
            done
          '';
        };

        testScript = ''
          start_all()
          machine.wait_for_unit("test-data-disk.service")

          with subtest("the base preset takes local snapshots without a backup server"):
              machine.fail("getent passwd idr-backup")
              machine.succeed("systemctl start --wait sanoid.service")
              snapshots = machine.succeed("zfs list -H -t snapshot -o name -r p1").splitlines()
              current = [
                  name for name in snapshots
                  if name.startswith("p1/application@autosnap_") and "2000-01-01" not in name
              ]
              assert len(current) == 1, current
              assert any(name.startswith("p1@autosnap_") for name in snapshots), snapshots

          with subtest("retention prunes old snapshots while Disko exclusions preserve them"):
              # Retention counts come from the start of a Sanoid pass. A second
              # run can retire the last old snapshot without going below hourly=1.
              machine.succeed("systemctl start --wait sanoid.service")
              snapshots = machine.succeed("zfs list -H -t snapshot -o name -r p1").splitlines()
              assert [name for name in snapshots if name.startswith("p1/application@")] == current
              expected = [
                  "autosnap_2000-01-01_00:00:00_hourly",
                  "autosnap_2000-01-01_01:00:00_hourly",
              ]
              for dataset in ["p1/cache", "p1/cache/child"]:
                  actual = [name for name in snapshots if name.startswith(dataset + "@")]
                  assert actual == [dataset + "@" + name for name in expected], actual
              assert machine.succeed("zfs get -H -o value idr:snapshots p1/cache/child").strip() == "false"
        '';
      };
    };
  };
}

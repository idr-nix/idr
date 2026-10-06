top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
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
  in {
    checks = {
      backup-client-selection = pkgs.testers.runNixOSTest {
        name = "backup-client-selection";
        node.pkgsReadOnly = false;
        globalTimeout = 10 * 60;

        nodes.machine = {
          imports = [(lib.modules.importApply ./fixtures/backup-machine.nix backupTop)];
          idr.preset.base.id = "bac000000001";
          idr.backup.client.datasets = ["p1/application"];
          disko.devices.zpool.p1.datasets = lib.genAttrs ["application" "other"] (_: {
            type = "zfs_fs";
            options.mountpoint = "none";
          });
          specialisation.disabled.configuration.idr.backup.client.enable = lib.mkForce false;
        };

        testScript = ''
          start_all()
          machine.wait_for_unit("idr-backup-access.service")
          machine.succeed("systemctl start --wait sanoid.service")

          with subtest("select a dataset instead of exposing the whole pool"):
              for dataset in ["p1", "p1/application", "p1/other"]:
                  snapshot = machine.succeed(
                      "zfs list -H -t snapshot -o name " + dataset
                  ).splitlines()[0]
                  command = "runuser -u idr-backup -- zfs send " + snapshot + " >/dev/null"
                  if dataset == "p1/application":
                      machine.succeed(command)
                  else:
                      status, output = machine.execute("(" + command + ") 2>&1")
                      assert status != 0 and "permission denied" in output.lower(), output

          with subtest("disabling remote backup removes delegation without disabling local snapshots"):
              machine.succeed(
                  "/run/current-system/specialisation/disabled/bin/switch-to-configuration test",
                  timeout=180,
              )
              machine.fail("systemctl is-active idr-backup-access.service")
              assert machine.succeed("zfs allow p1/application").strip() == ""
              machine.succeed("systemctl start --wait sanoid.service")
              assert machine.succeed("zfs list -H -t snapshot -o name p1/application").strip()
        '';
      };
    };
  };
}

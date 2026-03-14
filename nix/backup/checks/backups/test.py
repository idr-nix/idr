import os
import shlex


def remote(command, key="/etc/ssh/backup-key"):
    return (
        f"ssh -n -F /dev/null -p 2222 -i {key} -o IdentitiesOnly=yes "
        "-o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=yes "
        "-o UserKnownHostsFile=/etc/test-known-hosts "
        f"idr-backup@{source_address} {shlex.quote(command)}"
    )


def take_snapshots():
    source.succeed("systemctl start sanoid.service")
    source.wait_until_succeeds("test $(systemctl show sanoid.service -p ActiveState --value) = inactive", timeout=30)
    source.succeed("test $(systemctl show sanoid.service -p Result --value) = success")


start_all()
source.wait_for_unit("idr-backup-access.service")
backup.wait_for_unit("idr-backup-prepare.service")
source.wait_for_unit("sshd.service")
source.wait_for_unit("disko-zfs.service")
source.succeed("printf initial > /source-data/value")
backup_system = backup.succeed("readlink -f /run/current-system").strip()
source_system = source.succeed("readlink -f /run/current-system").strip()

with subtest("Deployments create filesystems and update properties while preserving existing data"):
    source.succeed("zfs list src/data src/local/persist src/volume")
    assert source.succeed("zfs get -H -o value type src/volume").strip() == "volume"
    assert source.succeed("zfs get -H -o value compression src/data").strip() == "zstd"
    source.succeed(f"{source_system}/specialisation/datasets/bin/switch-to-configuration test")
    source.succeed("zfs list src/added")
    source.succeed("mountpoint -q /added")
    assert source.succeed("zfs get -H -o value compression src/data").strip() == "zstd-5"
    assert source.succeed("cat /source-data/value").strip() == "initial"
    source.succeed(f"{source_system}/bin/switch-to-configuration test")
    source.succeed("zfs list src/added")
    assert source.succeed("zfs get -H -o value compression src/data").strip() == "zstd"

with subtest("Team membership automatically creates a read-only backup account"):
    assert backup.succeed(remote("id -un")).strip() == "idr-backup"
    backup.fail(remote("true", key="/etc/test-rogue-key"))
    backup.fail(remote("zfs snapshot src/data@forbidden"))
    backup.fail(remote("zfs set compression=off src/data"))
    backup.fail(remote("zfs destroy src/data"))
    backup.fail(remote("/run/wrappers/bin/sudo -n true"))
    source.fail("zfs list -t snapshot src/data@forbidden")

with subtest("Snapshot exclusions are independent of replication exclusions"):
    take_snapshots()
    source.succeed("zfs list -r -H -t snapshot -o name src/data | grep autosnap_")
    source.succeed("zfs list -r -H -t snapshot -o name src/local/persist | grep autosnap_")
    assert source.succeed("zfs list -H -t snapshot -o name -r src/local/root").strip() == ""
    assert source.succeed("zfs list -H -t snapshot -o name -r src/local/nix").strip() == ""
    assert source.succeed("zfs list -H -t snapshot -o name src/volume").strip() == ""
    source.succeed("printf volume-data | dd of=/dev/zvol/src/volume status=none")
    source.succeed("zfs snapshot -r src@first")
    backup.fail(remote("zfs rollback src/data@first"))

with subtest("Deploy metadata supplies targets, ports, and SSH host-key pins"):
    backup.succeed(f"{backup_system}/specialisation/wrong-key/bin/switch-to-configuration test")
    backup.fail(f"systemctl start {backup_unit}")
    backup.fail(f"zfs list {destination}")
    backup.succeed(f"{backup_system}/bin/switch-to-configuration test")
    backup.succeed(f"systemctl start {backup_unit}")
    backup.succeed(f"zfs list {destination}/data@first {destination}/volume@first")
    assert source.succeed("zfs holds -H src@first").strip() == ""
    backup.fail(f"zfs list {destination}/local")
    assert backup.succeed(f"zfs get -H -o value readonly {destination}/data").strip() == "on"
    assert backup.succeed(f"zfs get -H -o value mountpoint {destination}/data").strip() == "none"
    assert backup.succeed(f"zfs get -H -o value syncoid:sync {destination}/data").strip() == "false"
    assert backup.succeed(f"dd if=/dev/zvol/{destination}/volume bs=11 count=1 status=none") == "volume-data"
    units = backup.succeed("systemctl list-unit-files 'idr-backup-*' --no-legend")
    assert "idr-backup-backup-" not in units
    assert "idr-backup-vm-" not in units

with subtest("Later runs replicate changes without granting write access to the source"):
    source.succeed("printf updated > /source-data/value; zfs snapshot -r src@second")
    backup.succeed(f"systemctl start {backup_unit}")
    backup.succeed(f"zfs list {destination}/data@first {destination}/data@second")
    backup.succeed(f"zfs set mountpoint=/restore {destination}/data")
    backup.succeed(f"zfs mount {destination}/data || mountpoint -q /restore")
    assert backup.succeed("cat /restore/value") == "updated"
    backup.fail("touch /restore/must-not-write")
    backup.succeed(f"zfs set mountpoint=none {destination}/data")

with subtest("QEMU credentials select peers in the same workspace"):
    backup.shutdown()
    qemu_options = os.environ.get("QEMU_OPTS")
    os.environ["QEMU_OPTS"] = (
        (qemu_options or "")
        + " -fw_cfg name=opt/io.systemd.credentials/idr.workspace-id,string=42b08923"
        + " -fw_cfg name=opt/io.systemd.credentials/idr.network-prefix-length,string=48"
    )
    try:
        backup.start()
    finally:
        if qemu_options is None:
            os.environ.pop("QEMU_OPTS")
        else:
            os.environ["QEMU_OPTS"] = qemu_options
    backup.wait_for_unit("idr-backup-prepare.service")
    backup.succeed(f"{backup_system}/specialisation/local/bin/switch-to-configuration test")
    source.succeed("zfs snapshot -r src@local-workspace")
    backup.succeed(f"systemctl start {backup_unit}")
    backup.succeed(f"zfs list {destination}/data@local-workspace")

with subtest("Disabling remote backups revokes access and keeps local snapshots"):
    source.succeed(f"{source_system}/specialisation/disabled/bin/switch-to-configuration test")
    source.fail("id idr-backup")
    backup.fail(remote("zfs list src/data"))
    assert "send" not in source.succeed("zfs allow src")
    assert "hold" not in source.succeed("zfs allow src")
    source.succeed("zfs create src/offline")
    take_snapshots()
    source.succeed("zfs list -r -H -t snapshot -o name src/offline | grep autosnap_")

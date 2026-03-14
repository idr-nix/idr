start_all()
controller.wait_for_unit("multi-user.target")
target.wait_for_unit("sshd.service")

environment = (
    "env PRJ_ROOT=/root/project PRJ_DATA_DIR=/root/project/.data "
    "SOPS_AGE_KEY_FILE=/root/project/.data/age-key "
)


def local(command):
    return controller.succeed(environment + command)


def anywhere(options="", success=True, extra_env=""):
    command = environment + extra_env + "idr-anywhere production -n " + options + " </dev/null 2>&1"
    status, output = controller.execute(command, timeout=300)
    assert (status == 0) == success, output
    controller.succeed("test -z \"$(find /root/project/.data -maxdepth 1 -name 'idr-disko-files-*' -print -quit)\"")
    assert not controller.succeed("git -C /root/project ls-files -- .data").strip()
    return output


with subtest("Prepare an offline deployment project"):
    local(setup)
    controller.succeed("test \"$(nix config show sandbox)\" = true")
    target.succeed("test \"$(nix config show sandbox)\" = true")

with subtest("Confirmations reject unknown tokens, missing consent and conflicting options"):
    assert "Unknown confirmations" in anywhere("--allow wipe_all_disks", success=False)
    assert "Missing confirmations: WIPE_ALL_DISKS" in anywhere(success=False)
    assert "Use only one" in anywhere(
        "--allow WIPE_ALL_DISKS --substitute-on-destination --no-substitute-on-destination", success=False
    )
    assert "cannot be overridden" in anywhere("--allow WIPE_ALL_DISKS --disko-mode disko", success=False)
    target.succeed("! blkid /dev/disk/by-id/virtio-installation-target")

with subtest("Installation preflight honors password and private-key overrides"):
    output = anywhere(
        "--env-password --ssh-option PubkeyAuthentication=no", success=False,
        extra_env="SSHPASS=fixture-password ",
    )
    assert "Missing confirmations: WIPE_ALL_DISKS" in output, output
    controller.succeed("mv /root/.ssh/id_ed25519 /root/project/.data/client-key")
    try:
        output = anywhere(
            "--ssh-option IdentitiesOnly=yes", success=False,
            extra_env='SSH_PRIVATE_KEY="$(cat /root/project/.data/client-key)" ',
        )
        assert "Missing confirmations: WIPE_ALL_DISKS" in output, output
    finally:
        controller.succeed("mv /root/project/.data/client-key /root/.ssh/id_ed25519")

with subtest("Interrupting installation removes staged plaintext"):
    controller.succeed(
        "systemd-run --unit=cancel-installation --property=Type=exec --setenv=PATH=/run/current-system/sw/bin "
        + environment + "idr-anywhere production -n --allow WIPE_ALL_DISKS "
        "--ssh-option 'ProxyCommand=sleep 60'"
    )
    controller.wait_until_succeeds(
        "find /root/project/.data -path '*/pre-format-files/disk-key.txt' | grep .", timeout=20
    )
    controller.succeed("systemctl stop cancel-installation.service")
    controller.succeed("test -z \"$(find /root/project/.data -maxdepth 1 -name 'idr-disko-files-*' -print -quit)\"")

with subtest("Real mount, swap file, and LUKS holders protect the running system"):
    target.succeed("mkfs.ext4 -F /dev/disk/by-id/virtio-installation-target", "mkdir -p /scratch", "mount /dev/disk/by-id/virtio-installation-target /scratch")
    assert "WIPE_NIXOS" in anywhere("--allow WIPE_ALL_DISKS", success=False)
    target.succeed("printf 'ID=linux\n' >/root/linux-os-release", "mount --bind /root/linux-os-release /etc/os-release")
    assert "WIPE_LINUX" in anywhere("--allow WIPE_ALL_DISKS", success=False)
    target.succeed("umount /etc/os-release")
    local(confirmations)
    target.succeed(
        "fallocate -l 32M '/scratch/swap file'",
        "chmod 600 '/scratch/swap file'",
        "mkswap '/scratch/swap file'",
        "swapon '/scratch/swap file'",
    )
    assert "WIPE_NIXOS" in anywhere("--allow WIPE_ALL_DISKS", success=False)
    target.succeed("swapoff '/scratch/swap file'", "umount /scratch")
    target.succeed(
        "printf password >/root/test-key",
        "cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --iter-time 1 --key-file /root/test-key /dev/disk/by-id/virtio-installation-target",
        "cryptsetup open --key-file /root/test-key /dev/disk/by-id/virtio-installation-target held-open",
    )
    assert "WIPE_NIXOS" in anywhere("--allow WIPE_ALL_DISKS", success=False)
    target.succeed("cryptsetup close held-open", "wipefs -a /dev/disk/by-id/virtio-installation-target")

with subtest("Native local build installs a real encrypted NixOS system, automatic hardware report and extra files"):
    facter_report_path = "/root/project/nix/machine/installation test/facter.json"
    controller.succeed("test ! -e " + shlex.quote(facter_report_path))
    output = anywhere("--allow WIPE_ALL_DISKS --build-on local --phases disko,install -L")
    assert "Installing NixOS" in output, output
    controller.succeed("test -s " + shlex.quote(facter_report_path))
    assert controller.succeed(
        "git -C /root/project ls-files -- 'nix/machine/installation test/facter.json'"
    ).strip() == "nix/machine/installation test/facter.json"
    hardware_report = controller.succeed("cat " + shlex.quote(facter_report_path))
    installed_system = local("nix eval --offline --raw /root/project#deploy.nodes.production.profiles.system.path.outPath").strip()
    assert installed_system != expected_system, "The generated report must change the installed system"
    assert target.succeed("cat /mnt/etc/fixture-hardware-report.json") == hardware_report
    assert target.succeed("cat /run/idr-installation-ssh-env").splitlines() == ["one", "two words"]
    target.succeed(
        "test ! -e /root/.config/nix/nix.conf",
        "mountpoint /mnt",
        "mountpoint /mnt/boot",
        "cryptsetup status installed-root",
        "test -s '/mnt/persist/fixture host key'",
        "test \"$(readlink -f /mnt/nix/var/nix/profiles/system)\" = '" + installed_system + "'",
        "test -s /mnt/boot/grub/grub.cfg",
        "touch /mnt/keep-this-file",
        "umount /mnt/boot /mnt",
        "cryptsetup close installed-root",
    )

with subtest("Native remote build keeps matching disk layouts and existing contents"):
    controller.succeed("printf true >/root/project/allow-discards.nix", "test ! -e '/root/project/hardware report.json'")
    # VM closure registration omits signatures; trust this fixture's declared inputs.
    local("nix store sign --all --key-file " + shlex.quote(cache_key))
    existing_scripts = set(target.succeed("find /nix/store -maxdepth 1 -name '*-idr-disko'").splitlines())
    output = anywhere(
        "--allow WIPE_ALL_DISKS --build-on remote --phases disko --substitute-on-destination -L "
        "--generate-hardware-config nixos-facter '/root/project/hardware report.json'"
    )
    assert "Building disko script" in output, output
    assert "Best-effort formatting failed" not in output, output
    controller.succeed("test -s '/root/project/hardware report.json'")
    assert controller.succeed(
        "git -C /root/project ls-files -- 'hardware report.json'"
    ).strip() == "hardware report.json"
    assert controller.succeed("cat " + shlex.quote(facter_report_path)) == hardware_report
    target.succeed("grep -Fx 'extra-substituters = ' /root/.config/nix/nix.conf")
    installed_scripts = set(target.succeed("find /nix/store -maxdepth 1 -name '*-idr-disko'").splitlines())
    new_scripts = installed_scripts - existing_scripts
    assert new_scripts, "The changed Disko configuration must be built on the target"
    for remote_script in new_scripts:
        controller.succeed("test ! -e " + shlex.quote(remote_script))
        target.succeed("test -x " + shlex.quote(remote_script))
    target.succeed(
        "test -f /mnt/keep-this-file",
        "cryptsetup status installed-root | grep -F discards",
        "umount /mnt/boot /mnt",
        "cryptsetup close installed-root",
    )

with subtest("Best-effort failure falls back to disko's full-wipe mode"):
    target.succeed(
        "cryptsetup luksChangeKey --batch-mode --pbkdf pbkdf2 --iter-time 1 --key-file /disk-key.txt "
        "/dev/disk/by-partlabel/disk-system-root /root/test-key"
    )
    output = anywhere("--allow WIPE_ALL_DISKS --build-on auto --phases disko --no-substitute-on-destination")
    assert "Best-effort formatting failed; retrying with a full disk wipe" in output, output
    assert controller.succeed("cat " + shlex.quote(facter_report_path)) == hardware_report
    target.succeed("mountpoint /mnt", "test ! -e /mnt/keep-this-file", "umount /mnt/boot /mnt", "cryptsetup close installed-root")

with subtest("Extra-file uploads validate keys and skip identical files"):
    target.succeed("rm -f /disk-key.txt")
    output = local("idr-copy-extra-files production")
    assert "Copied ssh_host_ed25519_key" in output, output
    original = target.succeed("stat -c '%i %y %a %U %G' '/persist/fixture host key'").strip()
    assert original.endswith("600 root root"), original
    output = local("idr-copy-extra-files production")
    assert "Unchanged:" in output and "Copied" not in output, output
    assert target.succeed("stat -c '%i %y %a %U %G' '/persist/fixture host key'").strip() == original
    target.succeed("test ! -e /disk-key.txt", "test -z \"$(find /persist -name '.idr-copy-*' -print -quit)\"")
    local("sops set '/root/project/nix/machine/installation test/secrets.enc.json' '[\"ssh_host_ed25519_key\"]' '\"invalid private key\"'")
    result, output = controller.execute(environment + "idr-copy-extra-files production 2>&1")
    assert result != 0 and "invalid or does not match" in output, output
    assert target.succeed("stat -c '%i %y %a %U %G' '/persist/fixture host key'").strip() == original

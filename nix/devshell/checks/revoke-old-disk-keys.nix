top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.rotate-keys-deploy;
    mkRevokeTest = name: scenario:
      pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./fixtures/rotation-project.nix {
            inherit top project system;
            rotated = true;
          })
        ];
        inherit name;

        testScript =
          ''
            import json
            import shlex

            # Keep repeated probes in one live devshell instead of re-evaluating it.
            def retry_in_shell(command):
                return "bash -c " + shlex.quote("until " + command + "; do sleep 1; done")

            start_all()
            machine.wait_for_unit("idr-project-fixture.service", timeout=600)
            machine.wait_for_unit("sshd.service")
            machine.wait_until_succeeds("ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q .")
            project = "cd /root/project && "
            shell = project + "nix --offline develop -c "

            def remote(command):
                return machine.succeed(shell + "ssh vm-test-machine " + shlex.quote(command), timeout=180)

            def check_key(device, source, succeeds=True):
                command = source + " | ssh vm-test-machine " + shlex.quote(
                    "cryptsetup open --type luks --test-passphrase --batch-mode --key-file - " + shlex.quote(device)
                )
                status, output = machine.execute(shell + "bash -o pipefail -c " + shlex.quote(command), timeout=180)
                # A bad passphrase returns 2; transport or device errors must fail the test.
                assert status == (0 if succeeds else 2), (device, status, output)

            def metadata(device):
                return json.loads(remote("cryptsetup luksDump --dump-json-metadata " + shlex.quote(device)))

            old_key = "cat .data/rotation-fixture/old-disk-key"
            new_key = "sops decrypt --extract '[\"disk_key\"]' nix/machine/test-machine/disk-key.enc.json"
          ''
          + scenario
          + ''
            daemon_started = False
            try:
                with subtest("start the rotated and verified generation"):
                    machine.succeed(project + "nix flake update team", timeout=600)
                    machine.succeed(shell + "idr -D", timeout=600)
                    daemon_started = True
                    machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                    machine.succeed(shell + retry_in_shell("bash -o pipefail -c " + shlex.quote(
                        "idr process get vm-test-machine -o json | jq -e '.[0].is_ready == \"Ready\"'"
                    )), timeout=900)
                    devices = json.loads(machine.succeed(project + "nix --offline eval --json "
                        ".#nixosConfigurations.test-machine.config.boot.initrd.luks.devices"))
                    assert len(devices) >= 2, "revocation must cover more than one encrypted disk"
                    for disk in devices.values():
                        assert disk["header"] is None, disk
                        check_key(disk["device"], old_key)
                        check_key(disk["device"], new_key)
                run_scenario(devices)
            except Exception:
                if daemon_started:
                    print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
                raise
            finally:
                if daemon_started:
                    machine.succeed(shell + "idr down", timeout=120)
          '';
      });
  in {
    checks = {
      revoke-old-disk-keys = mkRevokeTest "revoke-old-disk-keys" ''
        def run_scenario(devices):
            with subtest("add an independent manual key before revoking managed keys"):
                remote("umask 077; head -c 64 /dev/urandom > /run/manual-disk-key")
                manual_slots = {}
                for name, disk in devices.items():
                    device = disk["device"]
                    before = metadata(device)
                    machine.succeed(shell + "bash -o pipefail -c " + shlex.quote(
                        new_key + " | ssh vm-test-machine " + shlex.quote(
                            "cryptsetup luksAddKey --batch-mode --key-file - " + shlex.quote(device) + " /run/manual-disk-key"
                        )
                    ), timeout=180)
                    after = metadata(device)
                    added = set(after["keyslots"]) - set(before["keyslots"])
                    assert len(added) == 1, (before, after)
                    manual_slots[name] = added.pop()

            with subtest("revoke old managed keys and preserve the current and manual keys"):
                machine.succeed(shell + "idr-revoke-old-disk-keys vm-test-machine", timeout=600)
                remote("test -L /persist/var/lib/idr/disk-key-recovery/current")
                snapshots = {}
                for name, disk in devices.items():
                    device = disk["device"]
                    check_key(device, new_key)
                    check_key(device, old_key, succeeds=False)
                    remote("cryptsetup open --type luks --test-passphrase --batch-mode "
                           "--key-file /run/manual-disk-key " + shlex.quote(device))
                    snapshots[name] = metadata(device)
                    assert manual_slots[name] in snapshots[name]["keyslots"], snapshots[name]
                    assert len(snapshots[name]["keyslots"]) == 2, snapshots[name]

            with subtest("repeated revocation preserves every header and usable key"):
                machine.succeed(shell + "idr-revoke-old-disk-keys vm-test-machine", timeout=600)
                remote("test -L /persist/var/lib/idr/disk-key-recovery/current")
                for name, disk in devices.items():
                    device = disk["device"]
                    assert metadata(device) == snapshots[name]
                    check_key(device, new_key)
                    check_key(device, old_key, succeeds=False)
                    remote("cryptsetup open --type luks --test-passphrase --batch-mode "
                           "--key-file /run/manual-disk-key " + shlex.quote(device))
      '';
      revoke-old-disk-keys-preflight = mkRevokeTest "revoke-old-disk-keys-preflight" ''
        import re

        def run_scenario(devices):
            with subtest("refuse all revocation when the current key cannot unlock one disk"):
                last_device = list(devices.values())[-1]["device"]
                output = machine.succeed(shell + "bash -o pipefail -c " + shlex.quote(
                    new_key + " | ssh vm-test-machine " + shlex.quote(
                        "cryptsetup open --type luks --test-passphrase --verbose --batch-mode --key-file - "
                        + shlex.quote(last_device)
                    )
                ), timeout=180)
                current_match = re.search(r"Key slot ([0-9]+) unlocked\.", output)
                assert current_match is not None, output
                current_slot = current_match.group(1)
                machine.succeed(shell + "bash -o pipefail -c " + shlex.quote(
                    old_key + " | ssh vm-test-machine " + shlex.quote(
                        "cryptsetup luksKillSlot --batch-mode --key-file - " + shlex.quote(last_device) + " " + current_slot
                    )
                ), timeout=180)
                check_key(last_device, new_key, succeeds=False)
                snapshots = {name: metadata(disk["device"]) for name, disk in devices.items()}
                failure = machine.fail(shell + "idr-revoke-old-disk-keys vm-test-machine 2>&1", timeout=600)
                assert "Existing keyslots were kept" in " ".join(failure.split()), failure
                for name, disk in devices.items():
                    device = disk["device"]
                    assert metadata(device) == snapshots[name]
                    check_key(device, old_key)
                    check_key(device, new_key, succeeds=(device != last_device))
      '';
    };
  };
}

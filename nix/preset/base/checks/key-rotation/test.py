import hashlib
import json
import shlex


LUKS2_DEVICES = ("/dev/loop0", "/dev/loop1")
REVOKE = "/run/current-system/sw/bin/idr-revoke-old-disk-keys"


def read_json(path):
    return json.loads(machine.succeed(f"cat {shlex.quote(path)}"))


def key_id(name):
    return hashlib.sha256(f"test-disk-key-{name}".encode()).hexdigest()


def header_options(device):
    return "--header /var/lib/test-disks/1.header" if device == "/dev/loop1" else ""


def accepted(name, device, slot=None):
    slot_option = f"--key-slot {slot}" if slot is not None else ""
    status, output = machine.execute(
        f"cryptsetup open --test-passphrase --batch-mode {slot_option} "
        "--token-type idr-disk-key --disable-external-tokens "
        f"--key-file /etc/idr-test/key-{name} {header_options(device)} {device}"
    )
    assert status in (0, 2), output
    return status == 0


def assert_keys(*names):
    for device in LUKS2_DEVICES:
        for name in ("a", "b", "recovery"):
            assert accepted(name, device) == (name in names), (name, device)


def disk_metadata(device):
    return machine.succeed(
        f"cryptsetup luksDump --dump-json-metadata {header_options(device)} {device}"
    )


def managed_slots(device):
    tokens = json.loads(disk_metadata(device))["tokens"].values()
    managed = [token for token in tokens if token["type"] == "idr-disk-key"]
    assert len(managed) == 1, managed
    return managed[0]["keyslots"]


def recovery_link():
    return machine.succeed(f"readlink -f {current}").strip()


def activate(system, *, action="switch", fails=False):
    # Use nixos-rebuild's native transient service with prebuilt generations.
    command = (
        "systemd-run --wait --collect --pipe --service-type=exec "
        "--unit=nixos-rebuild-switch-to-configuration "
        f"{system}/bin/switch-to-configuration {action}"
    )
    if fails:
        machine.fail(command)
    else:
        machine.succeed(command)


start_all()
machine.wait_for_unit("multi-user.target")
machine.wait_for_unit("idr-disk-keys.service")
base = machine.succeed("readlink -f /run/current-system").strip()
same_key = f"{base}/specialisation/same-key"
rotated = f"{base}/specialisation/rotated"
current = "/persist/var/lib/idr/disk-key-recovery/current"
runtime = "/run/idr-disk-keys"
independent = disk_metadata("/dev/loop2")

with subtest("Boot labels the installed key and leaves manual LUKS2 keys unmarked"):
    assert machine.succeed(f"stat --format=%a {runtime}").strip() == "700"
    assert machine.succeed(f"stat --format=%a {runtime}/keys/{key_id('a')}").strip() == "600"
    assert_keys("a", "recovery")
    for device in LUKS2_DEVICES:
        slots = managed_slots(device)
        assert len(slots) == 1, slots
        assert accepted("a", device, slots[0])
        assert not accepted("recovery", device, slots[0])
    machine.fail(f"test -e {current}")

with subtest("Preparing an unchanged key leaves LUKS2 metadata untouched"):
    metadata = [disk_metadata(device) for device in LUKS2_DEVICES]
    machine.succeed("systemctl restart idr-disk-keys")
    assert [disk_metadata(device) for device in LUKS2_DEVICES] == metadata
    activate(base, action="dry-activate")
    activate(base, action="test")
    assert [disk_metadata(device) for device in LUKS2_DEVICES] == metadata
    machine.fail(f"test -e {current}")

with subtest("Plain deploy changes the SOPS identity without changing disk slots"):
    machine.succeed(
        f"mkdir -p /var/lib/test-deployment; cp {deployment_flake} /var/lib/test-deployment/flake.nix"
    )
    machine.succeed("deploy -s /var/lib/test-deployment#machine -- --offline -L")
    expected_system = machine.succeed(f"readlink -f {same_key}").strip()
    assert machine.succeed("readlink -f /run/current-system").strip() == expected_system
    assert [disk_metadata(device) for device in LUKS2_DEVICES] == metadata
    assert machine.succeed("cat /run/secrets/idr-disk-key") == "test-disk-key-a"
    assert_keys("a", "recovery")
    machine.fail(f"test -e {current}")

with subtest("Both failed and successful switches retain previous keys"):
    machine.succeed("touch /run/fail-activation")
    activate(rotated, fails=True)
    assert_keys("a", "b", "recovery")
    machine.fail(f"test -e {current}")
    machine.succeed("rm /run/fail-activation; systemctl restart test-activation")
    activate(rotated)
    assert_keys("a", "b", "recovery")
    for device in LUKS2_DEVICES:
        slots = managed_slots(device)
        assert len(slots) == 2, slots
        assert all(not accepted("recovery", device, slot) for slot in slots)
    machine.fail(f"test -e {current}")

with subtest("Revocation checks the current key on every disk before deleting any slot"):
    device = LUKS2_DEVICES[1]
    machine.succeed(
        f"cryptsetup luksRemoveKey --batch-mode {header_options(device)} "
        f"{device} /etc/idr-test/key-b"
    )
    machine.succeed(
        "cryptsetup token add --token-id 10 --key-slot 1 "
        f"--key-description idr-test-manual {header_options(device)} {device}"
    )
    manual_token = json.loads(disk_metadata(device))["tokens"]["10"]
    metadata = [disk_metadata(device) for device in LUKS2_DEVICES]
    # A manual keyring token can unlock the disk even when --key-file is wrong.
    # Revocation must verify the declared key itself, not accept that fallback.
    machine.succeed(
        "keyctl session - sh -eu -c "
        + shlex.quote(
            "keyctl padd user idr-test-manual @s < /etc/idr-test/key-recovery\n"
            "cryptsetup open --test-passphrase --batch-mode "
            f"--key-file /etc/idr-test/key-b {header_options(device)} {device}\n"
            f"if {REVOKE}; then exit 1; fi"
        )
    )
    assert [disk_metadata(device) for device in LUKS2_DEVICES] == metadata
    for device in LUKS2_DEVICES:
        assert accepted("a", device)
        assert accepted("recovery", device)
    machine.fail(f"test -e {current}")
    machine.succeed("systemctl restart idr-disk-keys")
    assert_keys("a", "b", "recovery")

with subtest("Recovery publication failure keeps old keys and permits retry"):
    recovery_directory = current.rsplit("/", 1)[0]
    machine.succeed(
        f"mkdir -p {recovery_directory}; "
        f"mount --bind {recovery_directory} {recovery_directory}; "
        f"mount -o remount,bind,ro {recovery_directory}"
    )
    metadata = [disk_metadata(device) for device in LUKS2_DEVICES]
    machine.fail(REVOKE)
    assert [disk_metadata(device) for device in LUKS2_DEVICES] == metadata
    assert_keys("a", "b", "recovery")
    machine.fail(f"test -e {current}")
    machine.fail(f"test -e {runtime}/recovery")
    machine.succeed(f"umount {recovery_directory}")
    machine.succeed(REVOKE)
    assert_keys("b", "recovery")
    assert json.loads(disk_metadata(LUKS2_DEVICES[1]))["tokens"]["10"] == manual_token
    for device in LUKS2_DEVICES:
        slots = managed_slots(device)
        assert len(slots) == 1, slots
        assert accepted("b", device, slots[0])

with subtest("Explicit revocation pins encrypted recovery without retaining the system closure"):
    bundle_b = recovery_link()
    bundle = read_json(current)
    manifest = read_json(bundle["manifest"])
    assert bundle["keyHash"] == key_id("b")
    assert manifest["ageSshKeyPaths"] == ["/persist/ssh/host-b"]
    roots = machine.succeed(f"nix-store --query --roots {bundle_b}")
    assert current in roots, roots
    references = machine.succeed(f"nix-store --query --requisites {bundle_b}")
    ciphertext = manifest["secrets"][0]["sopsFile"]
    assert ciphertext in references
    assert "ENC[" in machine.succeed(f"cat {ciphertext}")
    assert base not in references
    machine.fail(f"test -e {runtime}/recovery")

with subtest("An older generation recovers the current key after runtime state is lost"):
    machine.succeed(f"systemctl stop idr-disk-keys; rm -r {runtime}")
    activate(base)
    assert_keys("a", "b", "recovery")
    assert recovery_link() == bundle_b
    machine.fail(f"test -e {runtime}/recovery")
    machine.succeed(REVOKE)
    assert_keys("a", "recovery")
    bundle_a = recovery_link()
    assert bundle_a != bundle_b
    assert read_json(current)["keyHash"] == key_id("a")

with subtest("Native deploy-rs timeout rolls back without revoking either generation's key"):
    machine.succeed(f"nix-env --profile /nix/var/nix/profiles/system --set {profiles['base']}")
    machine.succeed(
        "systemd-run --no-block --unit=test-deploy-timeout --service-type=oneshot "
        "--setenv=PATH "
        f"{profiles['rotated']}/activate-rs activate {profiles['rotated']} "
        "--profile-path /nix/var/nix/profiles/system --auto-rollback --magic-rollback "
        "--confirm-timeout 5 --temp-path /run/test-deploy"
    )
    machine.wait_until_succeeds("systemctl is-failed test-deploy-timeout", timeout=180)
    machine.succeed("journalctl --boot --quiet --grep='Timeout elapsed for confirmation'")
    assert machine.succeed("readlink -f /run/current-system").strip() == base
    assert recovery_link() == bundle_a
    assert_keys("a", "b", "recovery")
    machine.succeed("systemctl reset-failed test-deploy-timeout")

with subtest("Independently keyed LUKS devices remain untouched"):
    assert disk_metadata("/dev/loop2") == independent
    assert accepted("a", "/dev/loop2")
    assert not accepted("b", "/dev/loop2")

import hashlib
import json
import shlex

start_all()
machine.wait_for_unit("multi-user.target")


def run(command):
    return machine.succeed("idr-test " + command + " </dev/null").strip()


def fail(command):
    return machine.fail("idr-test " + command + " </dev/null 2>&1").strip()


def state():
    return json.loads(run("idr process get vm-lifecycle -o json"))[0]


def logs():
    return run("idr process logs vm-lifecycle")


def wait_for_vm(command, timeout=60):
    try:
        machine.wait_until_succeeds("(idr-test " + command + ") </dev/null", timeout=timeout)
    except Exception:
        print(state())
        print(logs())
        raise


machine.succeed(
    "cp -rL /etc/idr-test-project /root/project; chmod -R u+w /root/project; "
    "cd /root/project; git init; git add .; "
    "git -c user.name=test -c user.email=test@example.invalid commit -m fixture; "
    "nix flake lock --offline; git add flake.lock"
)
host_id = machine.succeed("cat /etc/machine-id").strip()
data = "/root/project/.data"
disk_dir = f"{data}/{host_id}/lifecycle/qemu"
socket_dir = f"{data}/{host_id}/machine/lifecycle/qemu"
disk = f"{disk_dir}/disk.qcow2"
known_hosts = f"{data}/ssh-{hashlib.sha256(host_id.encode()).hexdigest()[:16]}.known_hosts"
machine.succeed(
    f"mkdir -p {disk_dir}; cp -L /etc/idr-test-disk.qcow2 {disk}; chmod u+w {disk}; "
    f"touch {known_hosts}; cp /etc/idr-test-key {data}/client-key; chmod 600 {data}/client-key"
)

with subtest("Process Compose keeps the project available while its VM is stopped"):
    # Give the detached controller its own session, independent of the driver's TTY.
    run("setsid idr -t=false -D")
    assert not state()["is_running"]
    run("idr process start vm-lifecycle")
    wait_for_vm("idr process logs vm-lifecycle | grep IDR_TEST_DISK_BOOTED")
    assert state()["is_running"]
    assert state()["is_ready"] == "Not Ready"
    machine.succeed(f"test -S {socket_dir}/serial.sock; test -S {socket_dir}/vnc.sock")
    machine.succeed("ip -6 address show dev idr0 | grep 'fd3e:aacc:e60e::1/48'")
    machine.succeed("test ! -e /etc/qemu/bridge.conf")
    output = fail("idrQemu")
    assert "another instance is already using lifecycle" in output
    machine.succeed(f"python3 /etc/idr-test-console.py {socket_dir}/vnc.sock")
    qemu_pid = machine.succeed("pgrep -f '[q]emu-system-x86_64 .*file=disk.qcow2'").strip()

with subtest("Wiping refuses production nodes and unsafe images"):
    assert "not a local QEMU VM" in fail("idr-wipe-local-vm lifecycle")
    assert state()["is_running"]
    run("idr process stop vm-lifecycle")
    machine.succeed(f"mv {disk} {disk}.real; ln -s {disk}.real {disk}")
    assert "outside the VM directory" in fail("idr-wipe-local-vm vm-lifecycle")
    machine.succeed(f"rm {disk}; mv {disk}.real {disk}")

    original_metadata = machine.succeed("cat /root/project/metadata.json")
    metadata = json.loads(original_metadata)
    metadata["disko"]["disks"]["main"]["imageName"] = "../outside"
    machine.succeed("printf %s " + shlex.quote(json.dumps(metadata)) + " > /root/project/metadata.json")
    assert "outside the VM directory" in fail("idr-wipe-local-vm vm-lifecycle")
    machine.succeed("printf %s " + shlex.quote(original_metadata) + " > /root/project/metadata.json")

    machine.succeed(
        f"mv {disk} {disk}.real; "
        f"qemu-img create -q -f qcow2 -o data_file={disk_dir}/external.raw {disk} 96M"
    )
    assert "external data file" in fail("idr-wipe-local-vm vm-lifecycle")
    machine.succeed(f"rm {disk} {disk_dir}/external.raw; mv {disk}.real {disk}")

    # A bad second image must be detected before the valid first image is touched.
    before = machine.succeed(f"sha256sum {disk}")
    metadata = json.loads(original_metadata)
    metadata["disko"]["disks"]["z-broken"] = {**metadata["disko"]["disks"]["main"], "imageName": "broken"}
    machine.succeed("printf %s " + shlex.quote(json.dumps(metadata)) + " > /root/project/metadata.json")
    machine.succeed(f"touch {disk_dir}/broken.qcow2")
    assert "Could not inspect" in fail("idr-wipe-local-vm vm-lifecycle")
    assert before == machine.succeed(f"sha256sum {disk}")
    machine.succeed("printf %s " + shlex.quote(original_metadata) + " > /root/project/metadata.json")
    machine.succeed(f"rm {disk_dir}/broken.qcow2")

    run("idr process start vm-lifecycle")
    machine.wait_until_succeeds(
        "pgrep -f '[q]emu-system-x86_64 .*file=disk.qcow2'", timeout=30
    )
    assert qemu_pid != machine.succeed("pgrep -f '[q]emu-system-x86_64 .*file=disk.qcow2'").strip()

with subtest("Wiping stops QEMU and clears the MBR and GPT headers"):
    run("idr-wipe-local-vm vm-lifecycle")
    assert not state()["is_running"]
    machine.succeed(f"test ! -e {known_hosts}")
    machine.succeed(f"qemu-img convert -f qcow2 -O raw {disk} {data}/wiped.raw")
    machine.succeed(
        "python3 - <<'PY'\n"
        "from pathlib import Path\n"
        f"data = Path('{data}/wiped.raw').read_bytes()\n"
        "assert all(data[offset:offset + 512] == bytes(512) for offset in (0, 512, len(data) - 512))\n"
        "PY"
    )

with subtest("Wiping preserves every byte outside the partition table headers"):
    # OVMF writes NvVars in the ESP during boot. Use a fresh image here so the
    # comparison measures only the wiper's changes, including all file contents.
    machine.succeed(f"cp -L /etc/idr-test-disk.qcow2 {disk}")
    run("idr-wipe-local-vm vm-lifecycle")
    machine.succeed(
        f"qemu-img convert -f qcow2 -O raw /etc/idr-test-disk.qcow2 {data}/expected.raw; "
        f"qemu-img convert -f qcow2 -O raw {disk} {data}/wiped.raw"
    )
    machine.succeed(
        "python3 - <<'PY'\n"
        "from pathlib import Path\n"
        f"expected = bytearray(Path('{data}/expected.raw').read_bytes())\n"
        "for offset in (0, 512, len(expected) - 512):\n"
        "    expected[offset:offset + 512] = bytes(512)\n"
        f"assert expected == Path('{data}/wiped.raw').read_bytes()\n"
        "PY"
    )
    run("idr-wipe-local-vm vm-lifecycle")
    run("idr process list")

with subtest("The wiped disk falls back to the actual installer ISO"):
    run("idr process start vm-lifecycle")
    wait_for_vm("idr process get vm-lifecycle -o json | jq -e '.[0].is_ready == \"Ready\"'", timeout=300)
    address = "fd3e:aacc:e60e:42b0:8923:1122:3344:5566"
    ssh = (
        f"ssh -6 -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no "
        f"-o UserKnownHostsFile=/dev/null -i {data}/client-key root@{address} "
    )
    output = machine.succeed(ssh + shlex.quote("cat /etc/os-release; ip -6 address show dev eno1"))
    assert "ID=nixos" in output
    assert address + "/48" in output
    machine.succeed(ssh + shlex.quote("test -b /dev/disk/by-id/nvme-eui.1122334455667788"))
    machine.succeed(ssh + shlex.quote("test -f /run/idr-qemu-ssh/root; test $(stat -c %a /run/idr-qemu-ssh/root) = 600"))
    machine.succeed(ssh + shlex.quote("echo IDR_TEST_INSTALLER_SERIAL > /dev/ttyS0"))
    wait_for_vm("idr process logs vm-lifecycle | grep IDR_TEST_INSTALLER_SERIAL")
    run("idr process stop vm-lifecycle")
    assert not state()["is_running"]
    run("idr down")

machine.succeed("! pgrep -f '[q]emu-system-x86_64'")

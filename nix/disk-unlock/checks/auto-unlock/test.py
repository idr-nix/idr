import json
import os


start_all()
server.wait_for_unit("idr-disk-unlock.socket")
client.wait_for_unit("multi-user.target")
client.wait_for_unit("idr-disk-unlock.socket")

with subtest("Unlock notifications and Podman DNS can listen on the same server"):
    server.succeed("podman load -i /etc/test-container-image.tar.gz")
    server.succeed("podman run -d --name dns-check --network podman idr-network-test:test")
    container = json.loads(server.succeed("podman inspect dns-check"))[0]
    container_address = container["NetworkSettings"]["Networks"]["podman"]["IPAddress"]
    for protocol in ("+notcp", "+tcp"):
        answers = server.succeed(
            f"dig +short +time=2 +tries=1 {protocol} @{dns_gateway} -p {dns_port} dns-check A"
        ).splitlines()
        assert container_address in answers, answers

with subtest("Only configured targets can request a callback"):
    server.succeed(f"printf 'unknown\n' | nc -N -w 5 {server_address} 64998")
    server.wait_until_succeeds("journalctl -b --no-pager -g 'Unknown disk-unlock target.'")

with subtest("Prepare a real encrypted root without building a separate disk image"):
    client.succeed(
        "cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 "
        f"--pbkdf-force-iterations 1000 --key-file {disk_key} /dev/vdb",
        f"cryptsetup open --key-file {disk_key} /dev/vdb cryptroot",
        "mkfs.ext4 -q /dev/mapper/cryptroot",
        f"nix-env --profile /nix/var/nix/profiles/system --set {encrypted}",
        f"{encrypted}/bin/switch-to-configuration boot",
    )
    server.succeed("systemctl stop idr-disk-unlock.socket")
    client.shutdown()
    client.start()

with subtest("An unavailable server is retried and a wrong host key cannot unlock the disk"):
    client.wait_for_console_text("Please enter passphrase for disk cryptroot")
    client.wait_for_console_text(f"{request_unit}.service: Failed")
    server.succeed("systemctl start idr-disk-unlock.socket")
    server.wait_until_succeeds(
        "test $(journalctl -b --no-pager -o cat -g 'Host key verification failed' | wc -l) -ge 2"
    )

with subtest("An unlock server does not authorize its own identity as an unlock client"):
    status, output = server.execute(
        "timeout 5 ssh -n -T -F /dev/null -p 2222 -i /etc/idr-test/client-key "
        "-o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none "
        "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/idr-test/known-hosts "
        f"-o HostKeyAlias={client_address} root@{client_address} 2>&1"
    )
    assert status != 0 and "Permission denied (publickey)" in output, output

with subtest("Correcting the host key lets the next request unlock and boot the client"):
    server.succeed(f"{correct_key}/bin/switch-to-configuration test")
    client.wait_for_unit("multi-user.target")
    assert client.succeed("findmnt -n -o SOURCE /").strip() == "/dev/mapper/cryptroot"
    client.fail(f"systemctl is-active {request_unit}.timer")
    client.succeed("echo persistent > /root/unlock-test")
    assert container_address in server.succeed(
        f"dig +short +time=2 +tries=1 +tcp @{dns_gateway} -p {dns_port} dns-check A"
    ).splitlines()

with subtest("An unlock server requests another server instead of notifying itself"):
    assert client.succeed(
        f"journalctl -b --quiet -o cat -u {request_unit}.service"
    ).strip()
    assert not client.succeed(
        f"journalctl -b --quiet -o cat -u {self_request_unit}.service -u {self_request_unit}.timer"
    ).strip()

with subtest("The unlock identity grants no SSH access after initrd"):
    status, output = server.execute(
        f"ssh -n -F /dev/null -i {unlock_key} -o BatchMode=yes -o IdentitiesOnly=yes "
        "-o IdentityAgent=none -o StrictHostKeyChecking=yes "
        "-o UserKnownHostsFile=/etc/idr-test/known-hosts "
        f"root@{client_address} true 2>&1"
    )
    assert status != 0 and "Permission denied (publickey)" in output, output

with subtest("Subsequent boots request a new unlock"):
    boot_id = client.succeed("cat /proc/sys/kernel/random/boot_id").strip()
    client.shutdown()
    client.start()
    client.wait_for_unit("multi-user.target")
    assert client.succeed("cat /proc/sys/kernel/random/boot_id").strip() != boot_id
    assert client.succeed("cat /root/unlock-test").strip() == "persistent"

with subtest("A local QEMU workspace does not notify the production unlock server"):
    client.shutdown()
    requests = int(server.succeed("systemctl show idr-disk-unlock.socket -p NAccepted --value"))
    qemu_options = os.environ.get("QEMU_OPTS")
    os.environ["QEMU_OPTS"] = (
        (qemu_options or "")
        + " -fw_cfg name=opt/io.systemd.credentials/idr.workspace-id,string=00000000"
        + " -fw_cfg name=opt/io.systemd.credentials/idr.network-prefix-length,string=48"
    )
    try:
        client.start()
    finally:
        if qemu_options is None:
            os.environ.pop("QEMU_OPTS")
        else:
            os.environ["QEMU_OPTS"] = qemu_options
    client.wait_for_console_text("ConditionCredential=!idr.workspace-id")
    client.wait_for_console_text("Please enter passphrase for disk cryptroot")
    client.send_console("public-test-disk-passphrase\n")
    client.wait_for_unit("multi-user.target")
    assert int(server.succeed("systemctl show idr-disk-unlock.socket -p NAccepted --value")) == requests

server.succeed("podman rm -f dns-check")

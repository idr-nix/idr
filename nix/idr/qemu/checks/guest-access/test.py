import hashlib
import json
import shlex
import time


start_all()
for machine in (client, guest):
    machine.wait_for_unit("multi-user.target")

project = "/tmp/project with spaces"
data = f"{project}/.data"
host_id = client.succeed("cat /etc/machine-id").strip()
agent_prefix = "ssh-" + hashlib.sha256(host_id.encode()).hexdigest()[:16]
key_directory = f"{data}/{host_id}/guest/qemu/ssh"
known_hosts = f"{data}/{agent_prefix}.known_hosts"
environment = {
    "PRJ_ROOT": project,
    "PRJ_DATA_DIR": data,
    "IDR_WORKSPACE_ID": "42b08923",
    "SOPS_AGE_KEY_FILE": f"{fixtures}/identity",
}


def command(text, **overrides):
    variables = {**environment, **overrides}
    prefix = " ".join(f"{name}={shlex.quote(value)}" for name, value in variables.items())
    return f"cd {shlex.quote(project)} && env {prefix} {client_shell} {text}"


def run(text, **overrides):
    return client.succeed(command(text, **overrides)).strip()


def ssh_config(options="", host="vm-guest", **overrides):
    output = run(f"ssh -G {options} {host}", **overrides)
    return dict(line.split(" ", 1) for line in output.splitlines())


def connect():
    return run(
        "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes vm-guest id -u"
    )


client.succeed(f"mkdir -p {shlex.quote(key_directory)} /root/.ssh")
client.succeed(f"cp {fixtures}/secrets.enc.json {shlex.quote(key_directory)}")
client.succeed(
    "printf 'Host *\\n  User fallback\\n  ControlMaster auto\\n  ControlPath /tmp/user-control\\n' > /root/.ssh/config"
)

with subtest("fw_cfg networking and authorization require the local workspace marker"):
    guest.wait_for_unit("idr-qemu-network.service")
    guest.wait_for_unit("idr-qemu-ssh.service")
    guest.succeed(f"ip -6 address show eno1 | grep -F '{address}/48'")
    guest.succeed("networkctl status eno1 | grep -F /run/systemd/network/01-idr-qemu.network")
    assert guest.succeed("cat /run/idr-qemu-ssh/root").strip() == public_key
    assert guest.succeed("stat -c %a /run/idr-qemu-ssh /run/idr-qemu-ssh/root").split() == ["700", "600"]
    client.succeed("test ! -e /run/systemd/network/01-idr-qemu.network")
    client.succeed("test ! -e /run/idr-qemu-ssh/root")
    client.wait_until_succeeds(f"ping -6 -c 1 {address}")

with subtest("entering the devshell configures SSH and authenticates with the encrypted key"):
    host_key = guest.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
    # Trust the key obtained through the test driver's independent control channel.
    client.succeed(
        f"printf '%s\\n' {shlex.quote('[' + address + ']:2222 ' + host_key)} > {shlex.quote(known_hosts)}"
    )
    assert connect() == "0"
    options = ssh_config()
    assert options["hostname"] == address
    assert options["user"] == "root"
    assert options["port"] == "2222"
    assert options["controlmaster"] == "false"
    assert options.get("controlpath", "none") == "none"
    agent_socket = options["identityagent"]

    config = f"{data}/{host_id}/ssh/42b08923.conf"
    client.succeed(f"test -L {shlex.quote(project + '/.data/ssh/' + system + '.template')}")
    before = client.succeed(f"stat -c '%i %Y' {shlex.quote(config)}")
    assert connect() == "0"
    assert client.succeed(f"stat -c '%i %Y' {shlex.quote(config)}") == before
    other = ssh_config(IDR_WORKSPACE_ID="12345678")
    assert other["hostname"] == "fd3e:aacc:e60e:1234:5678:1e6f:6e96:b47c"
    assert len(client.succeed(f"find {shlex.quote(data + '/' + host_id + '/ssh')} -name '*.conf'").splitlines()) == 2
    client.fail(command(
        "ssh -o BatchMode=yes -o ConnectTimeout=5 vm-guest true",
        IDR_WORKSPACE_ID="invalid",
    ))
    client.fail(
        f"SSH_AUTH_SOCK={shlex.quote(agent_socket)} ssh -F /dev/null -p 2222 "
        "-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost true"
    )

with subtest("SSH respects user configuration and explicit command-line options"):
    assert ssh_config(host="guest")["user"] == "fallback"
    overridden = ssh_config("-l nobody -o ControlMaster=auto -o ControlPath=/tmp/explicit")
    assert overridden["user"] == "nobody"
    assert overridden["controlmaster"] == "auto"
    assert overridden["controlpath"] == "/tmp/explicit"
    assert run(
        f"env IDR_SSH_CONFIG={shlex.quote(config)} SSH_OPTS='-F /does-not-exist' "
        "ssh -o BatchMode=yes vm-guest id -u"
    ) == "0"

with subtest("activation and service restarts preserve local guest access"):
    guest.succeed("/run/current-system/bin/switch-to-configuration test")
    guest.succeed("systemctl restart idr-qemu-network idr-qemu-ssh")
    assert connect() == "0"

with subtest("connections reuse the agent and refresh its idle timeout"):
    assert connect() == "0"
    inode = client.succeed(f"stat -c %i {shlex.quote(agent_socket)}")
    time.sleep(20)
    assert connect() == "0"
    assert client.succeed(f"stat -c %i {shlex.quote(agent_socket)}") == inode
    time.sleep(15)
    client.succeed(f"SSH_AUTH_SOCK={shlex.quote(agent_socket)} ssh-add -l")
    client.wait_until_succeeds(f"test ! -S {shlex.quote(agent_socket)}", timeout=40)

with subtest("SSH cannot decrypt with an unrelated identity and leaves the saved key intact"):
    secret = shlex.quote(key_directory + "/secrets.enc.json")
    before = client.succeed(f"cat {secret}")
    client.fail(command(
        "ssh -o BatchMode=yes -o ConnectTimeout=5 vm-guest id -u",
        SOPS_AGE_KEY_FILE=f"{fixtures}/wrong-identity",
    ))
    assert client.succeed(f"cat {secret}") == before
    assert connect() == "0"

with subtest("readiness follows rotated host keys without regenerating its command"):
    metadata = f"{project}/nix/machine/guest/secrets.enc.json"
    client.succeed(f"mkdir -p {shlex.quote(project + '/nix/machine/guest')}")

    def update_host_key():
        key = guest.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
        content = json.dumps({"ssh_host_ed25519_key_pub_unencrypted": key})
        client.succeed(f"printf %s {shlex.quote(content)} > {shlex.quote(metadata)}")

    update_host_key()
    client.wait_until_succeeds(command(readiness_command))
    guest.succeed("rm /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub")
    guest.succeed("ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key")
    guest.succeed("systemctl restart sshd")
    client.fail(command(readiness_command))
    update_host_key()
    client.wait_until_succeeds(command(readiness_command))

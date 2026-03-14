import json


def ssh(key):
    return (
        "ssh -n -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes "
        "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        f"-i /etc/test-{key}-key root@127.0.0.1 true"
    )


start_all()
server.wait_for_unit("multi-user.target")
server.wait_for_unit("sshd.service")

with subtest("base networking and additional loopback addresses"):
    server.wait_until_succeeds("ip -6 address show dev idr-lo | grep -F fd42::123/128")
    server.succeed("ping -c 1 10.123.0.1", "ping -6 -c 1 fd42::123")
    assert server.succeed("hostid").strip() == "123456ab"
    server.succeed("nft list ruleset", "systemctl is-active systemd-networkd")

with subtest("QEMU host bridge works without a connected VM"):
    server.wait_until_succeeds("ip -6 address show dev idr0 | grep -F fd3e:aacc:e60e::1/48")
    server.succeed("ip -6 route get fd3e:aacc:e60e::123 | grep 'dev idr0'")
    assert server.succeed("cat /etc/qemu/bridge.conf").strip() == "allow idr0"
    server.succeed("test -u /run/wrappers/bin/qemu-bridge-helper")

with subtest("NixOS containers are managed through the host with root locked"):
    server.wait_for_unit("container@example.service")
    assert server.succeed("nixos-container run example -- id -u").strip() == "0"
    root = server.succeed("nixos-container run example -- getent shadow root").split(":")
    assert root[1].startswith(("!", "*")), root

with subtest("Podman containers communicate using IPv4, IPv6 and DNS"):
    server.succeed("podman load -i /etc/test-container-image.tar.gz")
    for name in ("first", "second"):
        server.succeed(f"podman run -d --name {name} --network podman idr-network-test:test")
    second = json.loads(server.succeed("podman inspect second"))[0]
    addresses = second["NetworkSettings"]["Networks"]["podman"]
    for host in ("second", addresses["IPAddress"], f'[{addresses["GlobalIPv6Address"]}]'):
        response = server.succeed(f"podman exec first wget -qO- http://{host}:8080")
        assert response.strip() == "idr-network-ok"
    network = json.loads(server.succeed("podman network inspect podman"))[0]
    assert network["ipv6_enabled"] and network["dns_enabled"]
    assert {subnet["subnet"] for subnet in network["subnets"]} == {
        "10.88.0.0/16", "fda8:35f4:8bb1::/48"
    }
    assert "64999" in server.succeed("cat /etc/containers/containers.conf")
    server.succeed("podman rm -f first second")

with subtest("SSH grants expire without rebuilding the configuration"):
    server.succeed("date -u -s 2040-01-01")
    server.succeed(ssh("permanent"), ssh("temporary"))
    server.succeed("date -u -s 2042-01-01")
    server.fail(ssh("temporary"))
    server.succeed(ssh("permanent"))

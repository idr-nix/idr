start_all()
server.wait_for_unit("multi-user.target")
server.wait_for_unit("container@example.service")

original = server.succeed("readlink -f /run/current-system").strip()
invocation = "systemctl show container@example.service -p InvocationID --value"
version = "nixos-container run example -- cat /etc/container-version"
before = server.succeed(invocation).strip()
assert before
assert server.succeed(version) == "original"

with subtest("system changes reload the container without restarting it"):
    server.succeed(
        f"{original}/specialisation/container-reload/bin/switch-to-configuration test"
    )
    assert server.succeed(version) == "updated"
    assert server.succeed(invocation).strip() == before

with subtest("runtime changes restart the container and make its bind mount read-only"):
    server.succeed(
        "echo host-data > /var/lib/container-test/marker",
        "nixos-container run example -- touch /run/host-data/writable",
        f"{original}/specialisation/container-restart/bin/switch-to-configuration test",
    )
    server.wait_for_unit("container@example.service")
    assert server.succeed(invocation).strip() != before
    assert server.succeed(
        "nixos-container run example -- cat /run/host-data/marker"
    ).strip() == "host-data"
    server.fail("nixos-container run example -- touch /run/host-data/read-only")

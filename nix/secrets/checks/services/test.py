import shlex


def read(path):
    return machine.succeed(f"cat {shlex.quote(path)}")


def inode(path):
    return machine.succeed(f"stat -c %i {shlex.quote(path)}").strip()


def container(command):
    return machine.succeed(f"nixos-container run consumer -- {command}")


def invocation(service):
    return machine.succeed(f"systemctl show {service} -p InvocationID --value").strip()


start_all()
machine.wait_for_unit("multi-user.target")
machine.wait_for_unit("idr-secrets.service")
machine.wait_for_unit("container@consumer.service")
machine.succeed(
    "nixos-container run consumer -- systemctl is-active idr-secrets.service"
)
original = machine.succeed("readlink -f /run/current-system").strip()
secret_dir = "/run/idr-secrets"

with subtest("SOPS and dependent generators produce their declared formats"):
    assert read("/run/secrets/z-source") == "test_value"
    assert read(f"{secret_dir}/y-stdout") == "stdout:test_value"
    assert read(f"{secret_dir}/a-template") == "[stdout:test_value] $UNDECLARED"
    assert read(f"{secret_dir}/output-file") == "fixed output"
    assert read(f"{secret_dir}/retry") == "first"
    trailing = 'quote" backslash\\ dollar$\nsecond line\n\n'
    assert read(f"{secret_dir}/trailing") == trailing
    machine.succeed(
        "systemd-run --wait --pipe --collect "
        f"-p EnvironmentFile={secret_dir}/environment /run/current-system/sw/bin/printenv "
        "VALUE TRAILING > /run/secret-test/environment"
    )
    assert read("/run/secret-test/environment") == f"test_value\n{trailing}\n"

with subtest("secret groups allow only the intended reader"):
    assert (
        machine.succeed(f"stat -c '%a %U %G' {secret_dir}/a-template").strip()
        == "440 root keys_a-template"
    )
    assert (
        machine.succeed("stat -Lc '%a %U %G' /run/secrets/z-source").strip()
        == "440 root keys_z-source"
    )
    machine.succeed(f"su -s /bin/sh reader -c 'cat {secret_dir}/a-template'")
    machine.fail(f"su -s /bin/sh reader -c 'cat {secret_dir}/y-stdout'")
    machine.fail(f"su -s /bin/sh reader -c 'cat {secret_dir}/.input-hashes/a-template'")
    machine.succeed(
        f"chmod 0600 {secret_dir}/a-template; chgrp root {secret_dir}/a-template"
    )
    machine.succeed("systemctl reload idr-secrets.service")
    assert (
        machine.succeed(f"stat -c '%a %U %G' {secret_dir}/a-template").strip()
        == "440 root keys_a-template"
    )

with subtest("unchanged inputs and deleted outputs do not regenerate other files"):
    paths = [f"{secret_dir}/{name}" for name in ["a-template", "output-file", "retry"]]
    before = {path: inode(path) for path in paths}
    runs = read("/run/secret-test/stdout-runs")
    fixed_runs = read("/run/secret-test/output-file-runs")
    machine.succeed("systemctl reload idr-secrets.service")
    assert {path: inode(path) for path in paths} == before
    assert read("/run/secret-test/stdout-runs") == runs
    assert read("/run/secret-test/output-file-runs") == fixed_runs
    machine.succeed(f"rm {secret_dir}/y-stdout")
    machine.succeed("systemctl reload idr-secrets.service")
    assert read(f"{secret_dir}/y-stdout") == "stdout:test_value"
    assert {path: inode(path) for path in paths} == before
    assert read("/run/secret-test/stdout-runs") == runs + "run\n"
    assert read("/run/secret-test/output-file-runs") == fixed_runs

with subtest("a failed generator retains its prior value and retries cleanly"):
    retry_inode = inode(f"{secret_dir}/retry")
    machine.succeed(
        "printf second > /run/secret-test/input; touch /run/secret-test/fail"
    )
    machine.fail("systemctl reload idr-secrets.service")
    assert read(f"{secret_dir}/retry") == "first"
    assert inode(f"{secret_dir}/retry") == retry_inode
    machine.succeed(f"test ! -e {secret_dir}/.out; test ! -e {secret_dir}/.secret")
    machine.succeed("rm /run/secret-test/fail; systemctl reload idr-secrets.service")
    assert read(f"{secret_dir}/retry") == "second"

with subtest("containers decrypt inherited secrets with the shared read-only identity"):
    assert container("cat /run/secrets/z-source") == "test_value"
    assert (
        container(f"cat {secret_dir}/a-template") == "[stdout:test_value] $UNDECLARED"
    )
    assert container("sha256sum /etc/ssh/idr/test-host-key") == machine.succeed(
        "sha256sum /etc/ssh/idr/test-host-key"
    )
    container("test ! -w /etc/ssh/idr/test-host-key")
    for kind in ["reload", "restart"]:
        assert (
            container(f"cat /run/secret-test/template-{kind}") == "start:test_value\n"
        )

with subtest("a configuration switch updates dependants and removes obsolete secrets"):
    output_inode = inode(f"{secret_dir}/output-file")
    fixed_runs = read("/run/secret-test/output-file-runs")
    reload_invocation = invocation("reload-consumer.service")
    restart_invocation = invocation("restart-consumer.service")
    machine.succeed(
        f"{original}/specialisation/updated/bin/switch-to-configuration test"
    )
    machine.wait_for_unit("idr-secrets.service")
    machine.wait_for_unit("container@consumer.service")
    assert read("/run/secrets/z-source") == "another value"
    assert read(f"{secret_dir}/a-template") == "[stdout:another value] $UNDECLARED"
    assert inode(f"{secret_dir}/output-file") == output_inode
    assert read("/run/secret-test/output-file-runs") == fixed_runs + "run\n"
    machine.succeed(
        f"test ! -e {secret_dir}/obsolete; test ! -e {secret_dir}/.input-hashes/obsolete"
    )
    for name in ["reload-consumer", "restart-consumer"]:
        assert (
            read(f"/run/secret-test/{name}").splitlines()[-1]
            == "[stdout:another value] $UNDECLARED"
        )
    assert invocation("reload-consumer.service") == reload_invocation
    assert invocation("restart-consumer.service") != restart_invocation
    assert read("/run/secret-test/reloads") == "reload\n"
    machine.wait_until_succeeds(
        "nixos-container run consumer -- grep -q 'another value' /run/secrets/z-source"
    )
    assert (
        container(f"cat {secret_dir}/a-template")
        == "[stdout:another value] $UNDECLARED"
    )
    container(f"test ! -e {secret_dir}/obsolete")
    assert (
        container("cat /run/secret-test/template-reload").splitlines()[-1]
        == "reload:another value"
    )
    assert (
        container("cat /run/secret-test/template-restart").splitlines()[-1]
        == "start:another value"
    )

with subtest("systemd SOPS activation orders decryption before generation"):
    restart_invocation = invocation("restart-consumer.service")
    machine.succeed(
        f"{original}/specialisation/service-mode/bin/switch-to-configuration test"
    )
    machine.wait_for_unit("sops-install-secrets.service")
    machine.wait_for_unit("idr-secrets.service")
    assert read("/run/secrets/z-source") == "test_value"
    assert read(f"{secret_dir}/a-template") == "[stdout:test_value] $UNDECLARED"
    assert (
        container(f"cat {secret_dir}/a-template") == "[stdout:test_value] $UNDECLARED"
    )
    machine.wait_until_succeeds(
        f'test "$(systemctl show -p InvocationID --value restart-consumer.service)" != "{restart_invocation}"'
    )

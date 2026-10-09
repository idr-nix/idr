# Both scenarios start from a successful normal deployment, verified and stopped
# by the persistence check. Each consumer performs exactly one candidate deploy.
{
  top,
  lib,
  pkgs,
  project,
  automatic,
}:
pkgs.testers.runNixOSTest ({config, ...}: let
  inherit (config.node.pkgs.stdenv.hostPlatform) system;
  networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
  # Read metadata from the existing archive share so Darwin does not copy the
  # fixture's multi-GB image output into the test machine's store filesystem.
  projectDirectory =
    if pkgs.stdenv.hostPlatform.isDarwin
    then "/run/idr-project-archive"
    else toString project;
  automaticPython =
    if automatic
    then "True"
    else "False";
in {
  imports = [
    (lib.modules.importApply ./local-vm-fixture.nix {
      inherit top project system;
      useBackingImages = true;
    })
  ];

  idr.test.direnv.offline = true;
  name =
    if automatic
    then "local-vm-auto-rollback"
    else "local-vm-rollback";

  testScript = ''
    import json
    import shlex

    start_all()
    machine.wait_for_unit("idr-project-fixture.service", timeout=600)
    machine.wait_for_unit("systemd-networkd.service")
    machine.wait_until_succeeds(
        "ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6"
    )
    machine.wait_until_succeeds(
        "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
    )
    machine.succeed("cd /root/project && direnv allow")
    shell = "cd /root/project && direnv exec . "
    state = json.loads(machine.succeed("cat ${projectDirectory}/deployed-state.json"))
    predecessor = [state["current_system"], state["system_profile"]]

    def remote(command):
        return shell + "ssh vm-test-machine " + shlex.quote("bash -ec " + shlex.quote(command))

    def generation():
        return machine.succeed(remote(
            "readlink -f /run/current-system; readlink -f /nix/var/nix/profiles/system"
        ), timeout=120).splitlines()

    def assert_application():
        # This data and these identities were verified before the disks were exported.
        actual = machine.succeed(remote(
            "systemctl is-active --quiet my-app.service; "
            "zfs list p1/keep-me >/dev/null; "
            "findmnt -n -o SOURCE /p1/my-app; "
            "zfs get -H -o value compression p1/my-app; "
            "cat /p1/my-app/data; printf '\\n'; "
            "cat /var/lib/my-app/state; printf '\\n'; "
            "cat /persist/var/lib/my-app/state; printf '\\n'; "
            "id -u my-app; id -g my-app; cat /etc/machine-id; "
            "stat -c '%u %g %a' /p1/my-app /var/lib/my-app; "
            "stat -c '%u %g' /p1/my-app/data /var/lib/my-app/state"
        ), timeout=120).splitlines()
        ownership = state["owner"] + " " + state["group"]
        expected = [
            "p1/my-app", "lz4", state["dataset_data"], state["state_data"],
            state["state_data"], state["owner"], state["group"], state["machine_id"],
            ownership + " 700", ownership + " 700", ownership, ownership,
        ]
        assert actual == expected, (actual, expected)

    def assert_predecessor():
        machine.succeed(remote("test ! -e /etc/idr-rollback-test"), timeout=120)
        restored = generation()
        assert restored == predecessor, (restored, predecessor)
        assert_application()

    def add_configuration(line):
        configuration = "nix/machine/test-machine/configuration.nix"
        edit = "/networking.hostName =/a\\      " + line
        machine.succeed("cd /root/project && sed -i " + shlex.quote(edit)
            + " " + configuration + " && git add " + configuration)

    daemon_started = False
    try:
        with subtest("boot and verify the exported deployed predecessor"):
            machine.succeed(shell + "idr -D", timeout=600)
            daemon_started = True
            machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
            readiness = (
                "idr process get vm-test-machine -o json | "
                "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
            )
            machine.wait_until_succeeds(
                shell + "bash -o pipefail -c " + shlex.quote(readiness), timeout=900,
            )
            assert_predecessor()

        add_configuration('environment.etc."idr-rollback-test".text = "candidate";')
        if ${automaticPython}:
            with subtest("a failed candidate activation restores the deployed predecessor"):
                add_configuration('system.activationScripts.idr-rollback-failure = { '
                    'deps = [ "etc" ]; text = "echo expected-deployed-activation-failure >&2; false"; };')
                status, output = machine.execute(shell + "bash -c " + shlex.quote(
                    "deploy -s .#vm-test-machine -- -L 2>&1"
                ), timeout=900)
                assert 0 < status < 124, (status, output)
                assert "expected-deployed-activation-failure" in output.splitlines(), output
                assert_predecessor()
        else:
            with subtest("deploy one working candidate generation"):
                machine.succeed(shell + "deploy -s .#vm-test-machine -- -L", timeout=900)
                marker = machine.succeed(remote("cat /etc/idr-rollback-test"), timeout=120)
                assert marker == "candidate", marker
                candidate = generation()
                assert len(candidate) == 2, candidate
                assert candidate[0] != predecessor[0], candidate
                assert candidate[1] != predecessor[1], candidate
                assert_application()

            with subtest("nixos-rebuild rollback restores the deployed predecessor"):
                machine.succeed(
                    shell + "ssh vm-test-machine nixos-rebuild switch --rollback --no-reexec",
                    timeout=900,
                )
                assert_predecessor()
    except Exception:
        if daemon_started:
            print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
        raise
    finally:
        if daemon_started:
            machine.succeed(shell + "idr down", timeout=120)
            machine.wait_until_succeeds(
                shell + "bash -c " + shlex.quote(
                    "idr process get vm-test-machine -o json; status=$?; "
                    'test "$status" -gt 0 && test "$status" -lt 124'
                ), timeout=60,
            )
  '';
})

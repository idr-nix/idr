top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-installation = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        name = "local-vm-installation";
        globalTimeout = lib.mkForce (60 * 60);

        testScript = ''
          import shlex

          # Keep repeated probes in one live devshell instead of re-evaluating it.
          def retry_in_shell(command):
              return "bash -c " + shlex.quote("until " + command + "; do sleep 1; done")

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6"
          )
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          def shell(command):
              return "su - root -c " + shlex.quote(
                  "cd /root/project && nix --offline develop -c " + command
              )
          readiness = (
              "idr process get vm-test-machine -o json | "
              "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
          )
          daemon_started = False
          try:
              with subtest("start the existing local VM"):
                  machine.succeed(shell("idr -D"), timeout=600)
                  daemon_started = True
                  machine.succeed(shell("idr process start vm-test-machine"), timeout=120)
                  machine.succeed(
                      shell(retry_in_shell("bash -o pipefail -c " + shlex.quote(readiness))), timeout=900,
                  )
                  assert machine.succeed(
                      shell("ssh vm-test-machine hostname"), timeout=120,
                  ).strip() == "test-machine"
                  original_boot = machine.succeed(
                      shell("ssh vm-test-machine cat /proc/sys/kernel/random/boot_id")
                  ).strip()
                  assert original_boot

              with subtest("wipe the local VM and start its installer ISO"):
                  machine.succeed(shell("idr-wipe-local-vm vm-test-machine"), timeout=300)
                  stopped = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and (.[0].is_running | not)'"
                  )
                  machine.succeed(shell("bash -o pipefail -c " + shlex.quote(stopped)))
                  machine.succeed(shell("idr process start vm-test-machine"), timeout=120)
                  machine.succeed(
                      shell(retry_in_shell("ssh vm-test-machine systemctl is-active idr-qemu-installer.service")),
                      timeout=900,
                  )
                  installer_boot = machine.succeed(
                      shell("ssh vm-test-machine cat /proc/sys/kernel/random/boot_id")
                  ).strip()
                  assert installer_boot and installer_boot != original_boot

              with subtest("install the configured machine with the required confirmation"):
                  # Add an observable change that only the newly installed system has.
                  configuration = "nix/machine/test-machine/configuration.nix"
                  edit = (
                      '/networking.hostName =/a\\      '
                      'environment.etc."installation-test".text = "installed with idr-anywhere";'
                  )
                  machine.succeed(
                      "cd /root/project && sed -i " + shlex.quote(edit) + " " + configuration
                      + " && git add " + configuration
                  )
                  machine.succeed(
                      shell("idr-anywhere vm-test-machine --allow WIPE_ALL_DISKS -n "
                            "--build-on local --no-substitute-on-destination -L"),
                      timeout=1800,
                  )

              with subtest("boot and automatically unlock the freshly installed system"):
                  installed = (
                      'test "$(ssh vm-test-machine hostname)" = test-machine && '
                      'test "$(ssh vm-test-machine cat /etc/installation-test)" = '
                      + shlex.quote("installed with idr-anywhere")
                  )
                  machine.succeed(shell(retry_in_shell("bash -ec " + shlex.quote(installed))), timeout=900)
                  installed_boot = machine.succeed(
                      shell("ssh vm-test-machine cat /proc/sys/kernel/random/boot_id")
                  ).strip()
                  assert installed_boot and installed_boot != installer_boot
                  machine.succeed(
                      shell(retry_in_shell("bash -o pipefail -c " + shlex.quote(readiness))), timeout=120,
                  )
          except Exception:
              if daemon_started:
                  print(machine.execute(shell("idr process logs --tail 1000 vm-test-machine"), timeout=120))
              raise
          finally:
              if daemon_started:
                  machine.succeed(shell("idr down"), timeout=120)
                  machine.wait_until_fails(shell("idr process get vm-test-machine -o json"), timeout=60)
        '';
      });
    };
  };
}

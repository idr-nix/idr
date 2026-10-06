top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-reboot = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        name = "local-vm-reboot";

        testScript = ''
          import shlex

          # Repeated probes share one live devshell and retain their outer timeout.
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

          shell = "cd /root/project && nix --offline develop -c "
          daemon_started = False
          try:
              with subtest("start the VM and wait for the installed system"):
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  readiness = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                  )
                  machine.succeed(
                      shell + retry_in_shell("bash -o pipefail -c " + shlex.quote(readiness)),
                      timeout=900,
                  )
                  boot_id = machine.succeed(
                      shell + "ssh vm-test-machine cat /proc/sys/kernel/random/boot_id",
                      timeout=120,
                  ).strip()
                  assert boot_id, "the installed system must expose a boot ID"

              with subtest("reboot the guest and unlock its disks automatically again"):
                  machine.succeed(shell + "ssh vm-test-machine reboot", timeout=120)
                  after_reboot = (
                      'current_boot_id=$(ssh vm-test-machine cat /proc/sys/kernel/random/boot_id) && '
                      'test -n "$current_boot_id" && test "$current_boot_id" != '
                      + shlex.quote(boot_id)
                      + " && test \"$(ssh vm-test-machine hostname)\" = test-machine"
                  )
                  machine.succeed(
                      shell + retry_in_shell("bash -ec " + shlex.quote(after_reboot)),
                      timeout=900,
                  )
          except Exception:
              if daemon_started:
                  print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
              raise
          finally:
              if daemon_started:
                  machine.succeed(shell + "idr down", timeout=120)
                  machine.wait_until_fails(
                      shell + "idr process get vm-test-machine -o json", timeout=60,
                  )
        '';
      });
    };
  };
}

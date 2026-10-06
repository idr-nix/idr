top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
    mkDeployModeCheck = mode:
      pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        name = "local-vm-deploy-${mode}";

        # Every mode restores its own factory images and stages the same candidate
        # configuration before the driver starts the unchanged factory guest.
        defaults.systemd.services.idr-project-fixture.script = lib.mkAfter ''
          cd /root/project
          sed -i '/networking.hostName =/a\      environment.etc."idr-deploy-mode".text = "changed";' nix/machine/test-machine/configuration.nix
          git add nix/machine/test-machine/configuration.nix
        '';

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

          mode = "${mode}"
          shell = "cd /root/project && nix --offline develop -c "
          remote = shell + "ssh vm-test-machine "

          def current_system():
              return machine.succeed(remote + "readlink -f /run/current-system", timeout=120).strip()

          def system_profile():
              return machine.succeed(remote + "readlink -f /nix/var/nix/profiles/system", timeout=120).strip()

          daemon_started = False
          try:
              with subtest("start the local VM from the exported images"):
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
                  machine.succeed(remote + "test ! -e /etc/idr-deploy-mode", timeout=120)
                  original_system = current_system()
                  assert original_system.startswith("/nix/store/"), original_system
                  original_profile = system_profile()
                  assert original_profile.startswith("/nix/store/"), original_profile

              with subtest("deploy with --" + mode + " and check the running state"):
                  machine.succeed(shell + "deploy -s --" + mode + " .#vm-test-machine -- -L", timeout=900)
                  if mode == "test":
                      assert machine.succeed(remote + "cat /etc/idr-deploy-mode", timeout=120).strip() == "changed"
                      assert current_system() != original_system
                  else:
                      machine.succeed(remote + "test ! -e /etc/idr-deploy-mode", timeout=120)
                      assert current_system() == original_system
                  if mode == "dry-activate":
                      assert system_profile() == original_profile

              if mode != "dry-activate":
                  with subtest("reboot and check the activation mode's persistent state"):
                      boot_id = machine.succeed(
                          remote + "cat /proc/sys/kernel/random/boot_id", timeout=120,
                      ).strip()
                      assert boot_id
                      machine.succeed(remote + "reboot", timeout=120)
                      marker_check = (
                          'test "$(ssh vm-test-machine cat /etc/idr-deploy-mode)" = changed'
                          if mode == "boot"
                          else "ssh vm-test-machine test ! -e /etc/idr-deploy-mode"
                      )
                      machine.succeed(
                          shell + retry_in_shell("bash -ec " + shlex.quote(
                              'current=$(ssh vm-test-machine cat /proc/sys/kernel/random/boot_id) && '
                              'test -n "$current" && test "$current" != ' + shlex.quote(boot_id)
                              + " && " + marker_check
                          )),
                          timeout=900,
                      )
                      if mode == "boot":
                          assert current_system() != original_system
                      else:
                          assert current_system() == original_system
          except Exception:
              if daemon_started:
                  print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
              raise
          finally:
              if daemon_started:
                  with subtest("stop the project"):
                      machine.succeed(shell + "idr down", timeout=120)
                      machine.wait_until_fails(
                          shell + "idr process get vm-test-machine -o json", timeout=60,
                      )
        '';
      });
  in {
    checks = {
      local-vm-deploy-dry-activate = mkDeployModeCheck "dry-activate";
      local-vm-deploy-test = mkDeployModeCheck "test";
      local-vm-deploy-boot = mkDeployModeCheck "boot";
    };
  };
}

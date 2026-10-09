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

        idr.test.direnv.offline = true;
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
          machine.succeed("cd /root/project && direnv allow")

          shell = "cd /root/project && direnv exec . "
          remote = shell + "ssh vm-test-machine "

          def current_system():
              return machine.succeed(remote + "readlink -f /run/current-system", timeout=120).strip()

          def remote_script(script):
              return remote + shlex.quote("bash -ec " + shlex.quote(script))

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
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(readiness), timeout=900,
                  )
                  original_state = machine.succeed(
                      remote_script(
                          "test ! -e /etc/idr-deploy-mode; "
                          "readlink -f /run/current-system; "
                          "readlink -f /nix/var/nix/profiles/system"
                      ),
                      timeout=120,
                  ).strip().splitlines()
                  assert len(original_state) == 2, original_state
                  original_system, original_profile = original_state
                  assert original_system.startswith("/nix/store/"), original_system
                  assert original_profile.startswith("/nix/store/"), original_profile

              with subtest("deploy with --" + mode + " and check the running state"):
                  machine.succeed(shell + "deploy -s --" + mode + " .#vm-test-machine -- -L", timeout=900)
                  state_commands = [
                      "marker=$(cat /etc/idr-deploy-mode); printf '%s\\n' \"$marker\""
                      if mode == "test" else "test ! -e /etc/idr-deploy-mode",
                      "readlink -f /run/current-system",
                  ]
                  if mode == "dry-activate":
                      state_commands.append("readlink -f /nix/var/nix/profiles/system")
                  deployed_state = machine.succeed(
                      remote_script("; ".join(state_commands)), timeout=120,
                  ).strip().splitlines()
                  assert len(deployed_state) == (1 if mode == "boot" else 2), deployed_state
                  if mode == "test":
                      assert deployed_state[0] == "changed"
                      assert deployed_state[1] != original_system
                  else:
                      assert deployed_state[0] == original_system
                  if mode == "dry-activate":
                      assert deployed_state[1] == original_profile

              if mode != "dry-activate":
                  with subtest("reboot and check the activation mode's persistent state"):
                      boot_id = machine.succeed(
                          remote + "cat /proc/sys/kernel/random/boot_id", timeout=120,
                      ).strip()
                      assert boot_id
                      machine.succeed(remote + "reboot", timeout=120)
                      marker_check = (
                          'test "$(cat /etc/idr-deploy-mode)" = changed'
                          if mode == "boot"
                          else "test ! -e /etc/idr-deploy-mode"
                      )
                      reboot_check = (
                          'current=$(cat /proc/sys/kernel/random/boot_id) && '
                          'test -n "$current" && test "$current" != ' + shlex.quote(boot_id)
                          + " && " + marker_check
                      )
                      reboot_probe = "ssh vm-test-machine " + shlex.quote(
                          "bash -ec " + shlex.quote(reboot_check)
                      )
                      machine.wait_until_succeeds(shell + reboot_probe, timeout=900)
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
                      machine.wait_until_succeeds(
                          shell + "bash -c " + shlex.quote(
                              "idr process get vm-test-machine -o json; status=$?; "
                              'test "$status" -gt 0 && test "$status" -lt 124'
                          ), timeout=60,
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

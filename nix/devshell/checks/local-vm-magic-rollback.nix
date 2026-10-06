top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-magic-rollback = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        name = "local-vm-magic-rollback";

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

          shell = "cd /root/project && nix --offline develop -c "
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

              # Keep confirmation bounded; each SSH invocation must reconnect and authenticate.
              deploy_module = "nix/machine/test-machine/flake-module.nix"
              edit = (
                  '/flake.nixosConfigurations/i\\  '
                  'flake.deploy.nodes.vm-test-machine = { '
                  'activationTimeout = 120; confirmTimeout = 15; '
                  'sshOpts = ["-o" "ControlMaster=no" "-o" "ControlPath=none"]; };'
              )
              machine.succeed(
                  "cd /root/project && sed -i " + shlex.quote(edit) + " " + deploy_module
                  + " && git add " + deploy_module
              )

              configuration = "nix/machine/test-machine/configuration.nix"
              edit = (
                  '/networking.hostName =/a\\      '
                  'environment.etc."idr-rollback-test".text = "working";'
              )
              machine.succeed(
                  "cd /root/project && sed -i " + shlex.quote(edit) + " " + configuration
                  + " && git add " + configuration
              )
              with subtest("deploy a known working generation"):
                  machine.succeed(shell + "deploy -s .#vm-test-machine -- -L", timeout=900)
                  assert machine.succeed(
                      shell + "ssh vm-test-machine cat /etc/idr-rollback-test", timeout=120,
                  ).strip() == "working"
                  working_system = machine.succeed(
                      shell + "ssh vm-test-machine readlink -f /run/current-system", timeout=120,
                  ).strip()
                  working_profile = machine.succeed(
                      shell + "ssh vm-test-machine readlink -f /nix/var/nix/profiles/system", timeout=120,
                  ).strip()
                  assert working_system.startswith("/nix/store/"), working_system
                  assert working_profile.startswith("/nix/store/"), working_profile

              with subtest("deploy a configuration that prevents SSH confirmation"):
                  edit = (
                      '/networking.hostName =/a\\      '
                      'services.openssh.settings.PermitRootLogin = lib.mkForce "no";'
                  )
                  machine.succeed(
                      "cd /root/project && sed -i 's/= \"working\";/= \"unreachable\";/' " + configuration
                      + " && sed -i " + shlex.quote(edit) + " " + configuration
                  )
                  failure = machine.fail(
                      shell + "bash -c " + shlex.quote("deploy -s .#vm-test-machine -- -L 2>&1"),
                      timeout=900,
                  )
                  assert "Activation succeeded!" in failure, failure
                  assert "Permission denied" in failure, failure

              with subtest("verify the previous generation is active again"):
                  machine.succeed(
                      shell + retry_in_shell("bash -ec " + shlex.quote(
                          'test "$(ssh vm-test-machine cat /etc/idr-rollback-test)" = working'
                      )),
                      timeout=180,
                  )
                  assert machine.succeed(
                      shell + "ssh vm-test-machine readlink -f /run/current-system", timeout=120,
                  ).strip() == working_system
                  assert machine.succeed(
                      shell + "ssh vm-test-machine readlink -f /nix/var/nix/profiles/system", timeout=120,
                  ).strip() == working_profile
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
    };
  };
}

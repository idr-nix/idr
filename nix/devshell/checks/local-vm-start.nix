top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-start = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        inherit (pkgs.stdenv.hostPlatform) isDarwin;
        # Re-entering nix develop for every probe competes with nested TCG.
        pollExpression = predicate:
          if isDarwin
          then ''"until " + ${predicate} + "; do sleep 5; done"''
          else ''"until " + ${predicate} + "; do sleep 1; done"'';
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        name = "local-vm-start";

        testScript = ''
          import shlex

          def wait_for_stop_in_shell(command):
              return "bash -c " + shlex.quote(
                  "while true; do " + command + "; status=$?; "
                  'case "$status" in 124|137) exit "$status";; esac; '
                  'if test "$status" -ne 0; then break; fi; sleep 1; done'
              )

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
              with subtest("start the local VM following the documentation"):
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)

              with subtest("wait for the installed system and connect using its SSH alias"):
                  readiness = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                  )
                  machine.succeed(
                      shell + "bash -o pipefail -c " + shlex.quote(${pollExpression "readiness"}),
                      timeout=900,
                  )
                  assert machine.succeed(
                      shell + "ssh vm-test-machine hostname", timeout=120,
                  ).strip() == "test-machine"

              with subtest("reuse the exported images without replacing them"):
                  machine.succeed(
                      "cd /root/project && bash -ec '"
                      'image_cache=".data/$(cat /etc/machine-id)/test-machine/qemu"; '
                      'for image in .data/image-references/*.qcow2; do '
                      'test "$image" -ef "$image_cache/$(basename "$image")"; '
                      "done'"
                  )
          except Exception:
              if daemon_started:
                  print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
              raise
          finally:
              if daemon_started:
                  with subtest("stop the project"):
                      machine.succeed(shell + "idr down", timeout=120)
                      machine.succeed(
                          shell + wait_for_stop_in_shell("idr process get vm-test-machine -o json"), timeout=60,
                      )
        '';
      });
    };
  };
}

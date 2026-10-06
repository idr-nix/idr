top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-force = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        inherit (pkgs.stdenv.hostPlatform) isDarwin;
        # Keep repeated probes in one live devshell to avoid competing with nested TCG.
        pollExpression = predicate: ''"until " + ${predicate} + "; do sleep ${
            if isDarwin
            then "5"
            else "1"
          }; done"'';
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [(lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})];
        name = "local-vm-force";
        globalTimeout = lib.mkForce ((
            if isDarwin
            then 90
            else 45
          )
          * 60);

        testScript = ''
          import shlex

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          shell = "cd /root/project && nix --offline develop -c "
          daemon_started = False
          runner_started = False
          try:
              with subtest("write persistent data to the existing installed VM"):
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  readiness = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                  )
                  machine.succeed(shell + "bash -o pipefail -c " + shlex.quote(${pollExpression "readiness"}), timeout=900)
                  machine.succeed(
                      shell + "ssh vm-test-machine 'touch /persist/force-rebuild-marker && "
                      "sync && test -f /persist/force-rebuild-marker'",
                      timeout=120,
                  )

              with subtest("stop the managed VM and force new images using the standalone runner"):
                  machine.succeed(shell + "idr process stop vm-test-machine", timeout=120)
                  stopped = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and (.[0].is_running | not)'"
                  )
                  machine.succeed(shell + "bash -o pipefail -c " + shlex.quote(${pollExpression "stopped"}), timeout=120)
                  # A separate session supplies the foreground runner's terminal lifecycle.
                  machine.succeed(shell + "bash -ec " + shlex.quote(
                      "env IDR_QEMU_BUILD_MEMORY=unused-because-cli-wins setsid nix --offline -L run .#vm-test-machine -- --force --build-memory 4096 "
                      "> /tmp/forced-vm.log 2>&1 < /dev/null & echo $! > /tmp/forced-vm.pid"
                  ), timeout=600)
                  runner_started = True
                  rebuilt = (
                      "ssh vm-test-machine 'test ! -e /persist/force-rebuild-marker && "
                      "test \"$(hostname)\" = test-machine'"
                  )
                  machine.succeed(
                      shell + "bash -o pipefail -c " + shlex.quote(${pollExpression "rebuilt"}),
                      timeout=${
            if isDarwin
            then "3600"
            else "1800"
          },
                  )

              with subtest("all image files were replaced"):
                  machine.succeed(
                      "cd /root/project && bash -ec '"
                      'image_cache=".data/$(cat /etc/machine-id)/test-machine/qemu"; '
                      'for image in .data/image-references/*.qcow2; do '
                      'test -f "$image_cache/$(basename "$image")"; '
                      '! test "$image" -ef "$image_cache/$(basename "$image")"; '
                      "done'"
                  )
          except Exception:
              print(machine.execute("tail -n 150 /tmp/forced-vm.log"))
              if daemon_started:
                  print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
              raise
          finally:
              if runner_started:
                  machine.execute("kill -TERM -- -$(cat /tmp/forced-vm.pid)")
              if daemon_started:
                  machine.succeed(shell + "idr down", timeout=120)
                  machine.wait_until_fails(shell + "idr process get vm-test-machine -o json", timeout=60)
        '';
      });
    };
  };
}

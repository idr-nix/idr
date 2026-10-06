top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks = {
      local-vm-first-start = pkgs.testers.runNixOSTest ({config, ...}: let
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
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {
            inherit top project system;
            cachedImages = false;
          })
        ];
        name = "local-vm-first-start";
        globalTimeout = lib.mkForce ((
            if isDarwin
            then 90
            else 45
          )
          * 60);

        testScript = ''
          import json
          import shlex

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          shell = "cd /root/project && env IDR_QEMU_BUILD_MEMORY=4096 nix --offline develop -c "
          daemon_started = False
          try:
              with subtest("start a machine whose disk images have never been built"):
                  assert not machine.succeed("find /root/project/.data -name '*.qcow2' -print").strip()
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  readiness = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                  )
                  machine.succeed(
                      shell + "bash -o pipefail -c " + shlex.quote(${pollExpression "readiness"}),
                      timeout=${
            if isDarwin
            then "3600"
            else "1800"
          },
                  )
                  assert machine.succeed(shell + "ssh vm-test-machine hostname", timeout=120).strip() == "test-machine"

              with subtest("the first start created all configured disk images"):
                  disks = json.loads(machine.succeed(
                      "cd /root/project && nix --offline eval --json "
                      ".#nixosConfigurations.test-machine.config.disko.devices.disk "
                      "--apply 'disks: map (disk: disk.imageName) (builtins.attrValues disks)'"
                  ))
                  images = machine.succeed(
                      "find /root/project/.data -name '*.qcow2' -printf '%f\\n'"
                  ).splitlines()
                  assert disks and sorted(images) == sorted(f"{name}.qcow2" for name in disks), images
                  assert not machine.succeed(
                      "find /root/project/.data -name '*.raw' -o -name '*.partial'"
                  ).strip()
          except Exception:
              if daemon_started:
                  print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
              raise
          finally:
              if daemon_started:
                  machine.succeed(shell + "idr down", timeout=120)
                  machine.wait_until_fails(shell + "idr process get vm-test-machine -o json", timeout=60)
        '';
      });
    };
  };
}

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-runner-options = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];
        idr.test.direnv.offline = true;
        name = "local-vm-runner-options";

        testScript = ''
          import json
          import shlex

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          shell = "cd /root/project && direnv exec . "
          machine.succeed("cd /root/project && direnv allow")
          readiness = (
              "idr process get vm-test-machine -o json | "
              "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
          )

          def check_guest_resources(cores, memory_mib):
              resources = machine.succeed(
                  shell + "ssh vm-test-machine " + shlex.quote("nproc && cat /proc/meminfo"),
                  timeout=120,
              )
              cpu_count, meminfo = resources.split("\n", 1)
              assert int(cpu_count.strip()) == cores
              total_kib = int(next(line for line in meminfo.splitlines() if line.startswith("MemTotal:")).split()[1])
              # Firmware and the kernel reserve part of the configured RAM.
              assert (memory_mib - 256) * 1024 < total_kib < memory_mib * 1024, total_kib

          daemon_started = False
          try:
              with subtest("configure the runner's memory and CPU count in the machine configuration"):
                  edit = (
                      '/networking.hostName =/a\\      '
                      'idr.meta.preset.base.qemu = { memorySize = 2048; options = ["-smp" "1"]; };'
                  )
                  machine.succeed(
                      "cd /root/project && sed -i " + shlex.quote(edit)
                      + " nix/machine/test-machine/configuration.nix && git add nix/machine/test-machine/configuration.nix"
                  )
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  machine.wait_until_succeeds(shell + "bash -o pipefail -c " + shlex.quote(readiness), timeout=900)
                  check_guest_resources(1, 2048)

              with subtest("restart Process Compose with environment overrides for the next run"):
                  machine.succeed(shell + "idr down", timeout=120)
                  machine.wait_until_succeeds(
                      shell + "bash -c " + shlex.quote(
                          "idr process get vm-test-machine -o json; status=$?; "
                          'test "$status" -gt 0 && test "$status" -lt 124'
                      ), timeout=60,
                  )
                  daemon_started = False
                  options = json.dumps(["-m", "3072", "-smp", "2"])
                  machine.succeed(
                      shell + "env IDR_QEMU_EXTRA_OPTIONS_JSON=" + shlex.quote(options) + " idr -D",
                      timeout=600,
                  )
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  machine.wait_until_succeeds(shell + "bash -o pipefail -c " + shlex.quote(readiness), timeout=900)
                  check_guest_resources(2, 3072)
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
      });
    };
  };
}

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-workspaces = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "local-vm-workspaces";

        defaults.systemd.services.idr-project-fixture.script = lib.mkAfter ''
          git -C project commit -qm 'Initial project'
          git -C project worktree add -b local-feature ../project-local
          mkdir -p project-local/.data
          cp -a --reflink=auto --sparse=always project/.data/. project-local/.data/
        '';

        testScript = ''
          import ipaddress
          import json
          import os
          import shlex

          build_cores = int(os.environ.get("NIX_BUILD_CORES", "0"))
          qemu_environment = ""
          if build_cores > 0:
              qemu_environment = (
                  "env IDR_QEMU_EXTRA_OPTIONS_JSON="
                  + shlex.quote(json.dumps(["-smp", str(build_cores)])) + " "
              )

          def shell(directory, command):
              return (
                  "cd /root/" + directory + " && direnv exec . "
                  + qemu_environment + "bash -o pipefail -ec "
                  + shlex.quote(command)
              )

          def ready(directory):
              predicate = (
                  'idr process get vm-test-machine -o json | '
                  "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
              )
              machine.wait_until_succeeds(shell(directory, predicate), timeout=900)

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_until_succeeds("ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q .")
          started = []
          try:
              with subtest("start the same machine in the main checkout and linked worktree"):
                  for directory in ("project", "project-local"):
                      machine.succeed("cd /root/" + directory + " && direnv allow")
                      machine.succeed(shell(directory, "idr -D"), timeout=600)
                      started.append(directory)
                      machine.succeed(shell(directory, "idr process start vm-test-machine"), timeout=120)
                  for directory in started:
                      ready(directory)

              with subtest("each workspace reaches its own running VM"):
                  addresses = []
                  boot_ids = []
                  for directory in started:
                      lines = machine.succeed(shell(directory,
                          "ssh -G vm-test-machine; "
                          + "ssh vm-test-machine " + shlex.quote("echo " + directory + " > /persist/idr-workspace-test; cat /proc/sys/kernel/random/boot_id")
                      ), timeout=120).splitlines()
                      boot_ids.append(lines.pop().strip())
                      settings = dict(line.split(" ", 1) for line in lines)
                      addresses.append(ipaddress.IPv6Address(settings["hostname"]))
                  assert addresses[0] != addresses[1], addresses
                  assert boot_ids[0] and boot_ids[1] and boot_ids[0] != boot_ids[1], boot_ids
                  for directory in started:
                      assert machine.succeed(shell(directory, "ssh vm-test-machine cat /persist/idr-workspace-test"), timeout=120).strip() == directory

              with subtest("VMs in different workspaces can communicate through the shared bridge"):
                  for index, directory in enumerate(started):
                      machine.succeed(shell(directory,
                          "ssh vm-test-machine ping -6 -c 1 -W 5 " + str(addresses[1 - index])
                      ), timeout=120)

              with subtest("stopping one workspace leaves the other VM running"):
                  machine.succeed(shell("project", "idr down"), timeout=120)
                  started.remove("project")
                  machine.wait_until_succeeds(shell("project",
                      "if idr process get vm-test-machine -o json; then exit 1; else status=$?; fi; "
                      'test "$status" -lt 124'
                  ), timeout=60)
                  ready("project-local")
                  assert machine.succeed(shell("project-local",
                      "ssh vm-test-machine cat /persist/idr-workspace-test"
                  ), timeout=120).strip() == "project-local"
          finally:
              for directory in started:
                  machine.succeed(shell(directory, "idr down"), timeout=120)
        '';
      });
    };
  };
}

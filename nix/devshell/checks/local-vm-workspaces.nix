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

        name = "local-vm-workspaces";

        defaults.systemd.services.idr-project-fixture.script = lib.mkAfter ''
          git -C project commit -qm 'Initial project'
          git -C project worktree add -b local-feature ../project-local
          mkdir -p project-local/.data
          cp -a --reflink=auto --sparse=always project/.data/. project-local/.data/
        '';

        testScript = ''
          import ipaddress
          import shlex

          def shell(directory, command):
              return (
                  "cd /root/" + directory + " && "
                  + "env IDR_QEMU_EXTRA_OPTIONS_JSON="
                  + shlex.quote('["-m", "2048", "-smp", "2"]')
                  + " nix --offline develop -c bash -o pipefail -ec "
                  + shlex.quote(command)
              )

          def ready(directory):
              predicate = (
                  'idr process get vm-test-machine -o json | '
                  "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
              )
              machine.succeed(shell(directory,
                  "until bash -o pipefail -c " + shlex.quote(predicate) + "; do sleep 1; done"
              ), timeout=900)

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_until_succeeds("ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q .")
          started = []
          try:
              with subtest("start the same machine in the main checkout and linked worktree"):
                  for directory in ("project", "project-local"):
                      machine.succeed(shell(directory, "idr -D"), timeout=600)
                      started.append(directory)
                      machine.succeed(shell(directory, "idr process start vm-test-machine"), timeout=120)
                  for directory in started:
                      ready(directory)

              with subtest("each workspace reaches its own running VM"):
                  addresses = []
                  boot_ids = []
                  for directory in started:
                      machine.succeed(shell(directory,
                          "ssh -G vm-test-machine > /tmp/" + directory + "-ssh-config; "
                          + "ssh vm-test-machine " + shlex.quote("echo " + directory + " > /persist/idr-workspace-test; cat /proc/sys/kernel/random/boot_id")
                          + " > /tmp/" + directory + "-boot-id"
                      ), timeout=120)
                      settings = dict(line.split(" ", 1) for line in machine.succeed(
                          "cat /tmp/" + directory + "-ssh-config"
                      ).splitlines())
                      addresses.append(ipaddress.IPv6Address(settings["hostname"]))
                      boot_ids.append(machine.succeed("cat /tmp/" + directory + "-boot-id").strip())
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
                  machine.wait_until_fails(shell("project", "idr process get vm-test-machine -o json"), timeout=60)
                  ready("project-local")
                  assert machine.succeed(shell("project-local", "ssh vm-test-machine cat /persist/idr-workspace-test"), timeout=120).strip() == "project-local"
          finally:
              for directory in started:
                  machine.succeed(shell(directory, "idr down"), timeout=120)
        '';
      });
    };
  };
}

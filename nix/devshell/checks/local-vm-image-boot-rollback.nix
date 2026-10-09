top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-image-boot-rollback = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "local-vm-image-boot-rollback";
        globalTimeout = lib.mkForce (45 * 60);

        testScript = ''
          import json
          import shlex

          def ssh_script(command):
              return "ssh vm-test-machine " + shlex.quote("bash -e -o pipefail -c " + shlex.quote(command))

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )
          machine.succeed("cd /root/project && direnv allow")

          project = "cd /root/project && "
          shell = project + "direnv exec . "
          configuration = "nix/machine/test-machine/configuration.nix"
          daemon_started = False
          failed = False

          try:
              with subtest("boot the factory images with their configured NVMe identities"):
                  disks = json.loads(machine.succeed(project +
                      "nix --offline eval --json .#nixosConfigurations.test-machine.config.disko.devices.disk "
                      "--apply 'disks: map (disk: disk.device) (builtins.attrValues disks)'"
                  ))
                  assert disks and all(disk.startswith("/dev/disk/by-id/nvme-") for disk in disks), disks
                  disk_checks = "\n".join("test -b " + shlex.quote(disk) for disk in disks)
                  disk_checks += "\ntest ! -b /dev/vda"
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  ready = "idr process get vm-test-machine -o json | jq -e '.[0].is_ready == \"Ready\"'"
                  factory_checks = (
                      "readlink -f /run/current-system\n"
                      "readlink -f /nix/var/nix/profiles/system\n"
                      "cat /proc/sys/kernel/random/boot_id\n"
                      "test -x /nix/var/nix/profiles/system/deploy-rs-activate\n"
                      + disk_checks
                  )
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(ready), timeout=900,
                  )
                  factory_system, factory_profile, factory_boot = machine.succeed(
                      shell + ssh_script(factory_checks), timeout=900,
                  ).splitlines()

              with subtest("deploy a working generation and select the factory generation for boot"):
                  machine.succeed(project + "sed -i " + shlex.quote(
                      '/networking.hostName =/a\\      environment.etc."idr-image-rollback-marker".text = "candidate";'
                  ) + " " + configuration + " && git add " + configuration)
                  machine.succeed(shell + "deploy -s .#vm-test-machine -- -L", timeout=1200)
                  candidate_marker = machine.succeed(
                      shell + "ssh vm-test-machine cat /etc/idr-image-rollback-marker", timeout=120,
                  )
                  candidate_system = machine.succeed(
                      shell + "ssh vm-test-machine readlink -f /run/current-system", timeout=120,
                  ).strip()
                  assert candidate_marker == "candidate"
                  assert candidate_system != factory_system
                  output = machine.succeed(
                      shell + ssh_script(
                          "timeout 300 nixos-rebuild boot --rollback --install-bootloader --no-reexec 2>&1"
                      ), timeout=540,
                  )
                  for disk in disks:
                      assert disk in output, output
                  assert "installing the GRUB 2 boot loader on /dev/vda" not in output, output
                  selected_profile = machine.succeed(
                      shell + "ssh vm-test-machine readlink -f /nix/var/nix/profiles/system", timeout=120,
                  ).strip()
                  assert selected_profile == factory_profile, selected_profile

              with subtest("reboot into the original generation and its runtime disk configuration"):
                  boot_changed = (
                      'boot=$(ssh vm-test-machine cat /proc/sys/kernel/random/boot_id) && '
                      'test -n "$boot" && test "$boot" != ' + shlex.quote(factory_boot)
                  )
                  factory_checks = (
                      "readlink -f /run/current-system\n"
                      "readlink -f /nix/var/nix/profiles/system\n"
                      "test ! -e /etc/idr-image-rollback-marker\n"
                      + disk_checks
                  )
                  machine.succeed(shell + "ssh vm-test-machine reboot", timeout=120)
                  machine.wait_until_succeeds(
                      shell + "bash -ec " + shlex.quote(boot_changed), timeout=900,
                  )
                  generation = machine.succeed(
                      shell + ssh_script(factory_checks), timeout=900,
                  ).splitlines()
                  assert generation == [factory_system, factory_profile], generation
          except Exception:
              failed = True
              if daemon_started:
                  try:
                      print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
                  except Exception as error:
                      print("Could not collect VM logs:", error)
              raise
          finally:
              if daemon_started:
                  try:
                      status, output = machine.execute(shell + "idr down", timeout=120)
                  except Exception as error:
                      if not failed:
                          raise
                      print("idr down failed during cleanup:", error)
                  else:
                      if failed:
                          if status != 0:
                              print("idr down failed during cleanup:", status, output)
                      else:
                          assert status == 0, output
        '';
      });
    };
  };
}

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-image-rollback = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        name = "local-vm-image-rollback";
        globalTimeout = lib.mkForce (45 * 60);

        testScript = ''
          import json
          import shlex

          # Keep repeated probes in one live devshell instead of re-evaluating it.
          def retry_in_shell(command):
              return "bash -c " + shlex.quote("until " + command + "; do sleep 1; done")

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )
          project = "cd /root/project && "
          shell = project + "nix --offline develop -c "
          remote = shell + "ssh vm-test-machine "
          configuration = "nix/machine/test-machine/configuration.nix"
          daemon_started = False

          def add_configuration(line):
              machine.succeed(project + "sed -i " + shlex.quote(
                  "/networking.hostName =/a\\      " + line
              ) + " " + configuration + " && git add " + configuration)

          def assert_factory_generation():
              assert machine.succeed(remote + "readlink -f /run/current-system").strip() == factory_system
              assert machine.succeed(remote + "readlink -f /nix/var/nix/profiles/system").strip() == factory_profile
              machine.succeed(remote + "test ! -e /etc/idr-image-rollback-marker")

          try:
              with subtest("boot the factory images with their configured NVMe identities"):
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  ready = "idr process get vm-test-machine -o json | jq -e '.[0].is_ready == \"Ready\"'"
                  machine.succeed(shell + retry_in_shell("bash -o pipefail -c " + shlex.quote(ready)), timeout=900)
                  factory_system = machine.succeed(remote + "readlink -f /run/current-system").strip()
                  factory_profile = machine.succeed(remote + "readlink -f /nix/var/nix/profiles/system").strip()
                  factory_boot = machine.succeed(remote + "cat /proc/sys/kernel/random/boot_id").strip()
                  machine.succeed(remote + "test -x /nix/var/nix/profiles/system/deploy-rs-activate")
                  disks = json.loads(machine.succeed(project +
                      "nix --offline eval --json .#nixosConfigurations.test-machine.config.disko.devices.disk "
                      "--apply 'disks: map (disk: disk.device) (builtins.attrValues disks)'"
                  ))
                  assert disks and all(disk.startswith("/dev/disk/by-id/nvme-") for disk in disks), disks
                  for disk in disks:
                      machine.succeed(remote + "test -b " + shlex.quote(disk))
                  machine.succeed(remote + "test ! -b /dev/vda")

              with subtest("a failed first deployment reactivates the original image generation"):
                  add_configuration('environment.etc."idr-image-rollback-marker".text = "candidate";')
                  add_configuration('system.activationScripts.idr-image-rollback-failure = { '
                      'deps = [ "etc" ]; text = "echo expected-image-activation-failure >&2; false"; };')
                  status, output = machine.execute(shell + "bash -c " + shlex.quote(
                      "deploy -s .#vm-test-machine -- -L 2>&1"
                  ), timeout=1200)
                  assert status != 0, output
                  assert "expected-image-activation-failure" in output, output
                  assert_factory_generation()

              with subtest("deploy a working generation and select the factory generation for boot"):
                  machine.succeed(project + "sed -i '/system.activationScripts.idr-image-rollback-failure/d' "
                      + configuration + " && git add " + configuration)
                  machine.succeed(shell + "deploy -s .#vm-test-machine -- -L", timeout=1200)
                  assert machine.succeed(remote + "cat /etc/idr-image-rollback-marker").strip() == "candidate"
                  assert machine.succeed(remote + "readlink -f /run/current-system").strip() != factory_system
                  output = machine.succeed(shell + "bash -c " + shlex.quote(
                      "ssh vm-test-machine nixos-rebuild boot --rollback --install-bootloader --no-reexec 2>&1"
                  ), timeout=300)
                  for disk in disks:
                      assert disk in output, output
                  assert "installing the GRUB 2 boot loader on /dev/vda" not in output, output
                  assert machine.succeed(remote + "readlink -f /nix/var/nix/profiles/system").strip() == factory_profile

              with subtest("reboot into the original generation and its runtime disk configuration"):
                  machine.succeed(remote + "reboot", timeout=120)
                  machine.succeed(shell + retry_in_shell("bash -ec " + shlex.quote(
                      'boot=$(ssh vm-test-machine cat /proc/sys/kernel/random/boot_id) && '
                      'test -n "$boot" && test "$boot" != ' + shlex.quote(factory_boot)
                  )), timeout=900)
                  assert_factory_generation()
                  for disk in disks:
                      machine.succeed(remote + "test -b " + shlex.quote(disk))
          except Exception:
              if daemon_started:
                  print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
              raise
          finally:
              if daemon_started:
                  machine.succeed(shell + "idr down", timeout=120)
        '';
      });
    };
  };
}

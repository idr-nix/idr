top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-image-activation-rollback = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "local-vm-image-activation-rollback";
        globalTimeout = lib.mkForce (45 * 60);

        testScript = ''
          import json
          import shlex

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

          def add_configuration(line):
              machine.succeed(project + "sed -i " + shlex.quote(
                  "/networking.hostName =/a\\      " + line
              ) + " " + configuration + " && git add " + configuration)

          def ssh_script(command):
              return "ssh vm-test-machine " + shlex.quote("bash -ec " + shlex.quote(command))

          def remote_script(command):
              return shell + ssh_script(command)

          def assert_factory_generation():
              command = (
                  "readlink -f /run/current-system\n"
                  "readlink -f /nix/var/nix/profiles/system\n"
                  "test ! -e /etc/idr-image-rollback-marker"
              )
              generation = machine.succeed(remote_script(command)).splitlines()
              assert generation == [factory_system, factory_profile], generation

          try:
              with subtest("boot the factory images with their configured NVMe identities"):
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  ready = "idr process get vm-test-machine -o json | jq -e '.[0].is_ready == \"Ready\"'"
                  disks = json.loads(machine.succeed(project +
                      "nix --offline eval --json .#nixosConfigurations.test-machine.config.disko.devices.disk "
                      "--apply 'disks: map (disk: disk.device) (builtins.attrValues disks)'"
                  ))
                  assert disks and all(disk.startswith("/dev/disk/by-id/nvme-") for disk in disks), disks
                  disk_checks = "\n".join("test -b " + shlex.quote(disk) for disk in disks)
                  factory_checks = (
                      "readlink -f /run/current-system\n"
                      "readlink -f /nix/var/nix/profiles/system\n"
                      "test -x /nix/var/nix/profiles/system/deploy-rs-activate\n"
                      + disk_checks + "\ntest ! -b /dev/vda"
                  )
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(ready), timeout=900,
                  )
                  factory_system, factory_profile = machine.succeed(
                      remote_script(factory_checks), timeout=900,
                  ).splitlines()

              with subtest("a failed first deployment reactivates the original image generation"):
                  add_configuration('environment.etc."idr-image-rollback-marker".text = "candidate";')
                  add_configuration('system.activationScripts.idr-image-rollback-failure = { '
                      'deps = [ "etc" ]; text = "echo expected-image-activation-failure >&2; false"; };')
                  status, output = machine.execute(shell + "bash -c " + shlex.quote(
                      "deploy -s .#vm-test-machine -- -L 2>&1"
                  ), timeout=1200)
                  assert 0 < status < 124, (status, output)
                  assert "expected-image-activation-failure" in output, output
                  assert_factory_generation()

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

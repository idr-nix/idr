top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    networkPrefix = "fd42:1234:5678";
  in {
    checks = {
      local-vm-network-prefix = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {
            inherit top project system;
            cachedImages = false;
          })
        ];

        name = "local-vm-network-prefix";
        defaults.idr.qemu.networkPrefix = lib.mkForce networkPrefix;

        testScript = ''
          import ipaddress
          import shlex

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_until_succeeds("ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6")
          machine.wait_until_succeeds("ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q .")

          with subtest("set the same custom network prefix in the machine and its host"):
              edit = '/networking.hostName =/a\\      idr.qemu.networkPrefix = "${networkPrefix}";'
              configuration = "nix/machine/test-machine/configuration.nix"
              machine.succeed("cd /root/project && sed -i " + shlex.quote(edit) + " " + configuration + " && git add " + configuration)

          shell = "cd /root/project && env NIX_BUILD_CORES=2 IDR_QEMU_EXTRA_OPTIONS_JSON='[\"-m\",\"2048\",\"-smp\",\"2\"]' nix --offline develop -c "
          started = False
          try:
              with subtest("first start builds the machine with its custom network prefix"):
                  machine.succeed(shell + "idr -D", timeout=600)
                  started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  readiness = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                  )
                  # Keep readiness probes in one live devshell during the cold build.
                  machine.succeed(
                      shell + "bash -o pipefail -c " + shlex.quote("until " + readiness + "; do sleep 1; done"),
                      timeout=1500,
                  )

              with subtest("the generated SSH alias reaches the VM through the custom prefix"):
                  machine.succeed(shell + "bash -ec 'ssh -G vm-test-machine > /tmp/custom-prefix-ssh'", timeout=120)
                  settings = dict(line.split(" ", 1) for line in machine.succeed("cat /tmp/custom-prefix-ssh").splitlines())
                  address = ipaddress.IPv6Address(settings["hostname"])
                  assert address in ipaddress.IPv6Network("${networkPrefix}::/48"), address
                  assert machine.succeed(shell + "ssh vm-test-machine hostname", timeout=120).strip() == "test-machine"
                  machine.succeed("ping -6 -c 1 -W 5 " + str(address))

              with subtest("the VM can reach its host bridge address"):
                  machine.succeed(shell + "ssh vm-test-machine ping -6 -c 1 -W 5 ${networkPrefix}::1", timeout=120)
                  assert not machine.succeed("ip -6 address show dev idr0 to fd3e:aacc:e60e::1/128").strip()
          finally:
              if started:
                  machine.succeed(shell + "idr down", timeout=120)
        '';
      });
    };
  };
}

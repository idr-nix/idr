top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-manual-unlock = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        example = top.self.nixosConfigurations."example-${system}".config;
        networkPrefix = example.idr.qemu.networkPrefix;
        machineId = lib.concatStringsSep ":" (lib.genList (i: builtins.substring (i * 4) 4 example.idr.preset.base.id) 3);
        # The restored project is a standalone checkout, whose workspace ID is zero.
        address = "${networkPrefix}:0000:0000:${machineId}";
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "local-vm-manual-unlock";

        testScript = ''
          import shlex
          import time

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6"
          )
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          machine.succeed("cd /root/project && direnv allow")

          shell = "cd /root/project && direnv exec . "
          process = "idr process get vm-test-machine -o json | jq -e "
          ready = process + shlex.quote(
              'length == 1 and .[0].is_running and .[0].is_ready == "Ready"'
          )
          locked = process + shlex.quote(
              'length == 1 and .[0].is_running and .[0].is_ready != "Ready"'
          )
          initrd_key = " ".join(machine.succeed(
              "jq -r .initrd_ssh_host_ed25519_key_pub_unencrypted "
              "/root/project/nix/machine/test-machine/secrets.enc.json"
          ).split()[:2])
          assert initrd_key.startswith("ssh-ed25519 "), initrd_key
          initrd_scan = (
              "ssh-keyscan -6 -T 2 -p ${toString example.boot.initrd.network.ssh.port} "
              "-t ed25519 ${address} | awk '{print $2 \" \" $3}' | "
              "grep -Fx -- " + shlex.quote(initrd_key)
          )

          daemon_started = False
          try:
              with subtest("start the VM with automatic disk unlocking disabled"):
                  machine.succeed(shell + "env IDR_QEMU_AUTO_UNLOCK=false idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)

              with subtest("remain in initrd until the operator unlocks the disks"):
                  machine.wait_until_succeeds(initrd_scan, timeout=900)
                  # Cover two automatic-unlock polling intervals after SSH becomes available.
                  for attempt in range(3):
                      if attempt:
                          time.sleep(10)
                      machine.succeed(initrd_scan)
                      machine.succeed(shell + "bash -o pipefail -c " + shlex.quote(locked))

              with subtest("unlock the disks using the documented command"):
                  machine.succeed(shell + "idr-unlock-disks vm-test-machine", timeout=360)
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(ready), timeout=900,
                  )
                  assert machine.succeed(shell + "ssh vm-test-machine hostname", timeout=120).strip() == "test-machine"
          except Exception:
              if daemon_started:
                  print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
              raise
          finally:
              if daemon_started:
                  with subtest("stop the project"):
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

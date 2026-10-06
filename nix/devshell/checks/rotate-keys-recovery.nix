top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.rotate-keys-deploy;
  in {
    checks = {
      rotate-keys-recovery = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        example = top.self.nixosConfigurations."example-${system}".config;
        networkPrefix = example.idr.qemu.networkPrefix;
        machineId = lib.concatStringsSep ":" (lib.genList (i: builtins.substring (i * 4) 4 example.idr.preset.base.id) 3);
        address = "${networkPrefix}:0000:0000:${machineId}";
      in {
        imports = [
          (lib.modules.importApply ./fixtures/rotation-project.nix {
            inherit top project system;
            rotated = true;
          })
        ];
        name = "rotate-keys-recovery";
        globalTimeout = lib.mkForce (40 * 60);

        testScript = ''
          import json
          import shlex

          # Keep repeated probes in one live devshell instead of re-evaluating it.
          def retry_in_shell(command):
              return "bash -c " + shlex.quote("until " + command + "; do sleep 1; done")

          def bounded(command, seconds):
              return "timeout --kill-after=10 " + str(seconds) + " bash -euo pipefail -c " + shlex.quote(command)

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("sshd.service")
          machine.wait_until_succeeds("ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q .")
          project = "cd /root/project && "
          shell = project + "nix --offline develop -c "
          old_system = machine.succeed(project + "cat .data/rotation-fixture/old-system").strip()
          old_key = machine.succeed(project + "cat .data/rotation-fixture/old-initrd.pub").strip()
          old_fingerprint = machine.succeed(project + "ssh-keygen -lf .data/rotation-fixture/old-initrd.pub").split()[1]
          recovery_ssh = (
              "ssh -o UserKnownHostsFile=/root/project/.data/rotation-fixture/old-known-hosts "
              "-o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes vm-test-machine "
          )
          recovery_ssh_no_input = recovery_ssh.replace("ssh ", "ssh -n ", 1)
          daemon_started = False
          try:
              with subtest("start the current generation with manual disk unlocking"):
                  machine.succeed(project + "nix flake update team", timeout=600)
                  machine.succeed(shell + "env IDR_QEMU_AUTO_UNLOCK=false idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "bash -euo pipefail -c " + shlex.quote("\n".join([
                      bounded("idr process start vm-test-machine", 120),
                      bounded("idr-unlock-disks vm-test-machine", 600),
                      bounded(retry_in_shell("ssh -n vm-test-machine systemctl is-active idr-disk-keys.service"), 900),
                  ])), timeout=120 + 600 + 900)

              with subtest("revoke the old disk key and select the older boot generation"):
                  machine.succeed(shell + "bash -euo pipefail -c " + shlex.quote("\n".join([
                      bounded("idr-revoke-old-disk-keys vm-test-machine", 600),
                      "ssh -n vm-test-machine test -L /persist/var/lib/idr/disk-key-recovery/current",
                  ])), timeout=600)
                  devices = json.loads(machine.succeed(project + "nix --offline eval --json "
                      ".#nixosConfigurations.test-machine.config.boot.initrd.luks.devices"))
                  assert devices
                  rejected_keys = []
                  for disk in devices.values():
                      assert disk["header"] is None
                      command = "cat .data/rotation-fixture/old-disk-key | ssh vm-test-machine " + shlex.quote(
                          "cryptsetup open --type luks --test-passphrase --batch-mode --key-file - " + shlex.quote(disk["device"])
                      )
                      rejected_keys.append(
                          "if " + bounded(command, 180) + "; then echo 'old disk key still unlocks a disk' >&2; exit 1; "
                          # Only cryptsetup's bad-passphrase exit proves rejection.
                          'else status=$?; case "$status" in 2) ;; '
                          '*) echo "unexpected disk-key check exit: $status" >&2; exit 1 ;; esac; fi'
                      )
                  machine.succeed(shell + "bash -euo pipefail -c " + shlex.quote("\n".join(rejected_keys)),
                                  timeout=180 * len(rejected_keys))
                  machine.succeed(shell + "bash -euo pipefail -c " + shlex.quote("\n".join([
                      bounded("ssh -n vm-test-machine nixos-rebuild boot --rollback --no-reexec", 600),
                      bounded("ssh -n vm-test-machine reboot", 120),
                  ])), timeout=600 + 120)

              with subtest("choose the recorded fingerprint for the historical initrd"):
                  scan = (
                      "ssh-keyscan -6 -T 2 -p ${toString example.boot.initrd.network.ssh.port} -t ed25519 ${address} "
                      "| awk '{print $2 \" \" $3}' | grep -Fx -- " + shlex.quote(old_key)
                  )
                  machine.wait_until_succeeds(scan, timeout=900)
                  fingerprints = machine.succeed(project + "bash -o pipefail -c " + shlex.quote(
                      "nix --offline eval --raw .#deploy.nodes.vm-test-machine.profiles.system.path.idr.meta.initrdHostPublicKeys "
                      "--apply 'builtins.concatStringsSep \"\\n\"' | ssh-keygen -lf -"
                  ), timeout=180)
                  assert old_fingerprint in fingerprints, fingerprints
                  failure = machine.fail(shell + "idr-unlock-disks vm-test-machine --timeout 15sec 2>&1", timeout=120)
                  assert "Host key verification failed" in " ".join(failure.split()), failure
                  machine.succeed(shell + "idr-unlock-disks vm-test-machine --host-key-fingerprint "
                                  + shlex.quote(old_fingerprint), timeout=600)

              with subtest("the older generation recovers and reenrolls its disk key"):
                  recovered_system = machine.succeed(shell + "bash -euo pipefail -c " + shlex.quote("\n".join([
                      bounded(retry_in_shell(recovery_ssh_no_input + "systemctl is-active idr-disk-keys.service"), 900) + " > /dev/null",
                      recovery_ssh_no_input + "readlink -f /run/current-system",
                  ])), timeout=900).strip()
                  assert recovered_system == old_system
                  verified_keys = []
                  for disk in devices.values():
                      for source in [
                          "cat .data/rotation-fixture/old-disk-key",
                          "sops decrypt --extract '[\"disk_key\"]' nix/machine/test-machine/disk-key.enc.json",
                      ]:
                          command = source + " | " + recovery_ssh + shlex.quote(
                              "cryptsetup open --type luks --test-passphrase --batch-mode --key-file - " + shlex.quote(disk["device"])
                          )
                          verified_keys.append(bounded(command, 180))
                  machine.succeed(shell + "bash -euo pipefail -c " + shlex.quote("\n".join(verified_keys)),
                                  timeout=180 * len(verified_keys))
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

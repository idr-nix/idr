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
        idr.test.direnv.offline = true;
        name = "rotate-keys-recovery";
        globalTimeout = lib.mkForce (40 * 60);

        testScript = ''
          import json
          import shlex

          # Poll within the loaded environment; the driver bounds the complete wait.
          def retry_in_shell(command):
              return "bash -c " + shlex.quote("until " + command + "; do sleep 1; done")

          def grub_entry_for_init(contents, init_path):
              # Parse the menu blocks emitted by the pinned NixOS GRUB generator.
              menu = []
              paths = set()
              matches = []
              for line in contents.splitlines():
                  line = line.strip()
                  if not line or line.startswith("#"):
                      continue
                  if line.startswith(("submenu ", "menuentry ")):
                      words = shlex.split(line)
                      assert len(words) >= 3 and words[-1] == "{", line
                      assert not menu or menu[-1][0] == "submenu", line
                      assert words[1] and ">" not in words[1], line
                      menu.append((words[0], words[1]))
                      entry = ">".join(title for _, title in menu)
                      assert entry not in paths, entry
                      paths.add(entry)
                  elif line == "}" and menu:
                      menu.pop()
                  elif menu and line.endswith("{"):
                      raise AssertionError("Unsupported GRUB menu block: " + line)
                  elif menu and menu[-1][0] == "menuentry" and line.startswith("linux "):
                      init_arguments = [word for word in shlex.split(line) if word.startswith("init=")]
                      assert len(init_arguments) == 1, line
                      if init_arguments[0] == "init=" + init_path:
                          matches.append(">".join(title for _, title in menu))
              assert not menu, menu
              assert len(matches) == 1, (init_path, matches)
              return matches[0]

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("sshd.service")
          machine.wait_until_succeeds("ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q .")
          project = "cd /root/project && "
          shell = project + "direnv exec . "
          ready = "idr process get vm-test-machine -o json | jq -e '.[0].is_ready == \"Ready\"'"
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
                  machine.succeed(project + "direnv allow", timeout=180)
                  machine.succeed(shell + "env IDR_QEMU_AUTO_UNLOCK=false idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  machine.succeed(shell + "idr-unlock-disks vm-test-machine", timeout=600)
                  # Readiness verifies stage2 before ordinary SSH can learn the initrd key.
                  machine.succeed(shell + "bash -euo pipefail -c " + shlex.quote("\n".join([
                      retry_in_shell("bash -o pipefail -c " + shlex.quote(ready)),
                      retry_in_shell("ssh -n vm-test-machine systemctl is-active idr-disk-keys.service"),
                  ])), timeout=900)

              with subtest("revoke the old disk key and select the older boot generation"):
                  machine.succeed(shell + "idr-revoke-old-disk-keys vm-test-machine", timeout=600)
                  machine.succeed(shell + "ssh -n vm-test-machine test -L /persist/var/lib/idr/disk-key-recovery/current")
                  devices = json.loads(machine.succeed(project + "nix --offline eval --json "
                      ".#nixosConfigurations.test-machine.config.boot.initrd.luks.devices"))
                  assert devices
                  for disk in devices.values():
                      assert disk["header"] is None
                      command = "cat .data/rotation-fixture/old-disk-key | ssh vm-test-machine " + shlex.quote(
                          "cryptsetup open --type luks --test-passphrase --batch-mode --key-file - " + shlex.quote(disk["device"])
                      )
                      status, output = machine.execute(shell + "bash -o pipefail -c " + shlex.quote(command), timeout=180)
                      # Only cryptsetup's bad-passphrase exit proves rejection.
                      assert status == 2, (disk["device"], status, output)
                  old_init = machine.succeed(
                      shell + "ssh -n vm-test-machine " + shlex.quote("readlink -f " + shlex.quote(old_system + "/init"))
                  ).strip()
                  assert old_init.startswith("/nix/store/"), old_init
                  boot_directories = json.loads(machine.succeed(project + "nix --offline eval --json "
                      ".#nixosConfigurations.test-machine.config.boot.loader.grub.mirroredBoots "
                      "--apply 'map (boot: boot.path)'"))
                  assert boot_directories and len(set(boot_directories)) == len(boot_directories), boot_directories
                  selections = []
                  for directory in boot_directories:
                      menu = machine.succeed(shell + "ssh -n vm-test-machine "
                          + shlex.quote("cat " + shlex.quote(directory + "/grub/grub.cfg")))
                      selections.append((directory, grub_entry_for_init(menu, old_init)))
                  # Select an existing entry on every mirror without rebuilding the menus.
                  for directory, entry in selections:
                      machine.succeed(shell + "ssh -n vm-test-machine " + shlex.quote(
                          "grub-reboot --boot-directory=" + shlex.quote(directory) + " " + shlex.quote(entry)
                      ))
                      environment = machine.succeed(shell + "ssh -n vm-test-machine " + shlex.quote(
                          "grub-editenv " + shlex.quote(directory + "/grub/grubenv") + " list"
                      ))
                      assert "next_entry=" + entry in environment.splitlines(), (directory, environment)
                  machine.succeed(shell + "ssh -n vm-test-machine reboot", timeout=120)

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
                      retry_in_shell(recovery_ssh_no_input + "systemctl is-active idr-disk-keys.service") + " > /dev/null",
                      recovery_ssh_no_input + "readlink -f /run/current-system",
                  ])), timeout=900).strip()
                  assert recovered_system == old_system
                  for disk in devices.values():
                      for source in [
                          "cat .data/rotation-fixture/old-disk-key",
                          "sops decrypt --extract '[\"disk_key\"]' nix/machine/test-machine/disk-key.enc.json",
                      ]:
                          command = source + " | " + recovery_ssh + shlex.quote(
                              "cryptsetup open --type luks --test-passphrase --batch-mode --key-file - " + shlex.quote(disk["device"])
                          )
                          machine.succeed(shell + "bash -o pipefail -c " + shlex.quote(command), timeout=180)
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

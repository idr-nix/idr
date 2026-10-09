top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      rotate-keys-deploy = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        inherit (pkgs.stdenv.hostPlatform) isDarwin;
        archiveDirectory =
          if isDarwin
          then "/tmp/test-output"
          else "/tmp/shared";
        archivePath = "${archiveDirectory}/rotation-project.tar";
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./fixtures/rotation-project.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "rotate-keys-deploy";
        globalTimeout = lib.mkForce (45 * 60);

        # Write the large archive directly to the test output, outside the container's tmpfs.
        nodeDefaults.virtualisation.sharedDirectories.test-output = lib.mkIf isDarwin {
          source = ''"$out"'';
          target = "/tmp/test-output";
          securityModel = "none";
        };

        testScript = ''
          import json
          import shlex

          # Poll within the loaded environment; the driver bounds the complete wait.
          def retry_in_shell(command):
              return "bash -c " + shlex.quote("until " + command + "; do sleep 1; done")

          ${lib.optionalString (!isDarwin) ''
            # Nspawn binds this exact directory at /tmp/shared when it starts.
            machine.shared_dir = machine.out_dir
          ''}
          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("sshd.service")
          machine.succeed("touch ${archiveDirectory}/.idr-write-check")
          assert (machine.out_dir / ".idr-write-check").is_file()
          machine.succeed("rm ${archiveDirectory}/.idr-write-check")
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )
          project = "cd /root/project && "
          shell = project + "direnv exec . "
          ready = "idr process get vm-test-machine -o json | jq -e '.[0].is_ready == \"Ready\"'"
          daemon_started = False
          try:
              with subtest("start the existing VM with an enrolled operator"):
                  machine.succeed(project + "nix flake update team", timeout=600)
                  machine.succeed(project + "direnv allow", timeout=180)
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  machine.succeed(shell + retry_in_shell("bash -o pipefail -c " + shlex.quote(ready)), timeout=900)
                  old_boot, old_system = machine.succeed(shell + "ssh -n vm-test-machine " + shlex.quote(
                      "bash -euc " + shlex.quote(
                          "cat /proc/sys/kernel/random/boot_id; readlink -f /run/current-system"
                      )
                  )).strip().splitlines()
                  assert old_boot and old_system.startswith("/nix/store/"), (old_boot, old_system)
                  machine.succeed(project + "mkdir -m 700 .data/rotation-fixture")
                  machine.succeed(project + "printf %s " + shlex.quote(old_system) + " > .data/rotation-fixture/old-system")
                  old_secrets = json.loads(machine.succeed(project + "cat nix/machine/test-machine/secrets.enc.json"))
                  old_host = old_secrets["ssh_host_ed25519_key_pub_unencrypted"].split()[:2]
                  old_initrd = old_secrets["initrd_ssh_host_ed25519_key_pub_unencrypted"].split()[:2]
                  machine.succeed(project + "printf '%s\\n' " + shlex.quote("* " + " ".join(old_host))
                                  + " > .data/rotation-fixture/old-known-hosts")
                  # Retain only synthetic test material for the revocation and recovery consumer checks.
                  machine.succeed(shell + "bash -euc " + shlex.quote(
                      "umask 077; sops decrypt --extract '[\"disk_key\"]' nix/machine/test-machine/disk-key.enc.json "
                      "> .data/rotation-fixture/old-disk-key"
                  ))

              with subtest("rotate, copy the versioned SSH keys, and deploy"):
                  machine.succeed(shell + "idr-rotate-keys --force vm-test-machine", timeout=600)
                  # Source edits invalidate the watched environment before copying and deploying.
                  machine.succeed(shell + "idr-copy-extra-files vm-test-machine", timeout=600)
                  machine.succeed(shell + "deploy -s .#vm-test-machine -- -L", timeout=1200)
                  current_system = machine.succeed(shell + "ssh -n vm-test-machine readlink -f /run/current-system").strip()
                  assert current_system != old_system, (old_system, current_system)
                  new_secrets = json.loads(machine.succeed(project + "cat nix/machine/test-machine/secrets.enc.json"))
                  assert new_secrets["ssh_host_ed25519_key_pub_unencrypted"].split()[:2] != old_host
                  assert new_secrets["initrd_ssh_host_ed25519_key_pub_unencrypted"].split()[:2] != old_initrd
                  history = [key.split()[:2] for key in new_secrets["initrd_ssh_host_ed25519_key_pub_history_unencrypted"]]
                  assert old_initrd in history, history
                  machine.succeed(project + "printf '%s\\n' " + shlex.quote(" ".join(old_initrd))
                                  + " > .data/rotation-fixture/old-initrd.pub")
                  machine.succeed(project + "printf %s " + shlex.quote(current_system) + " > .data/rotation-fixture/current-system")
                  machine.succeed(shell + "ssh -n vm-test-machine systemctl is-active idr-disk-keys.service")

              with subtest("reboot and unlock with the newly deployed keys"):
                  rebooted = retry_in_shell("ssh -n vm-test-machine " + shlex.quote(
                      "bash -ec " + shlex.quote(
                          'boot=$(cat /proc/sys/kernel/random/boot_id) && '
                          'test -n "$boot" && test "$boot" != ' + shlex.quote(old_boot)
                          + ' && test "$(readlink -f /run/current-system)" = ' + shlex.quote(current_system)
                      )
                  ))
                  machine.succeed(shell + "ssh -n vm-test-machine reboot", timeout=120)
                  machine.succeed(shell + rebooted, timeout=900)
                  machine.succeed(shell + "ssh -n vm-test-machine systemctl is-active idr-disk-keys.service")

              with subtest("export the verified generation for revocation and recovery tests"):
                  stopped = retry_in_shell("bash -o pipefail -c " + shlex.quote(
                      "idr process get vm-test-machine -o json | jq -e '.[0].is_running == false'"
                  ))
                  machine.succeed(shell + "ssh -n vm-test-machine poweroff", timeout=120)
                  machine.succeed(shell + stopped, timeout=180)
                  machine.succeed(shell + "idr down", timeout=120)
                  daemon_started = False
                  # Clear the fixture's temporary identities so its agents can exit promptly.
                  agent_sockets = machine.succeed(
                      "find /root/project/.data -maxdepth 1 -type s -name 'ssh-*.sock' -print"
                  ).splitlines()
                  for socket in agent_sockets:
                      status, output = machine.execute(
                          "SSH_AUTH_SOCK=" + shlex.quote(socket)
                          + " ${config.node.pkgs.openssh}/bin/ssh-add -D"
                      )
                      # An agent can expire between listing its socket and contacting it.
                      assert status in (0, 2), (socket, status, output)
                  # Temporary SSH agents may still create locks or remove sockets in .data.
                  machine.wait_until_fails(
                      "${config.node.pkgs.procps}/bin/pgrep -f '[i]dr-ssh-key.nu watch'",
                      timeout=60,
                  )
                  machine.succeed(
                      "cd /root/project && mv .data/$(cat /etc/machine-id)/test-machine/qemu .data/images && "
                      "find .data -mindepth 1 -maxdepth 1 ! -name images ! -name rotation-fixture -exec rm -rf {} +"
                  )
                  machine.succeed(
                      "bash -o pipefail -c 'tar -C /root --exclude=project/.git --sparse --sort=name --mtime=@0 "
                      "--owner=0 --group=0 --numeric-owner -c project .config/idr team > ${archivePath}'",
                      timeout=600,
                  )
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

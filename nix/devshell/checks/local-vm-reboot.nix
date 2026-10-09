top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-reboot = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        inherit (pkgs.stdenv.hostPlatform) isDarwin;
        archiveDirectory =
          if isDarwin
          then "/tmp/test-output"
          else "/tmp/shared";
        example = top.self.nixosConfigurations."example-${system}".config;
        networkPrefix = example.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "local-vm-reboot";

        # Write the images directly into the output instead of copying an archive twice.
        nodeDefaults.virtualisation.sharedDirectories.test-output = lib.mkIf isDarwin {
          source = ''"$out"'';
          target = archiveDirectory;
          securityModel = "none";
        };

        testScript = ''
          import shlex

          ${lib.optionalString (!isDarwin) ''
            machine.shared_dir = machine.out_dir
          ''}
          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6"
          )
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          shell = "cd /root/project && direnv exec . "
          machine.succeed("cd /root/project && direnv allow")
          swap_devices = ${builtins.toJSON (map (swap: toString swap.realDevice) example.swapDevices)}
          assert swap_devices, "the installed guest must have configured swap devices"

          def check_guest_swap():
              for device in swap_devices:
                  quoted_device = shlex.quote(device)
                  checks = (
                      'systemctl is-active --quiet "$(systemd-escape --path --suffix=swap '
                      + quoted_device + ')" && test -b ' + quoted_device
                      + ' && udevadm info --query=all --name=' + quoted_device
                  )
                  machine.wait_until_succeeds(
                      shell + "ssh vm-test-machine " + shlex.quote(checks), timeout=120,
                  )

          daemon_started = False
          try:
              with subtest("start the VM and wait for the installed system"):
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  readiness = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                  )
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(readiness),
                      timeout=900,
                  )
                  boot_id = machine.succeed(
                      shell + "ssh vm-test-machine cat /proc/sys/kernel/random/boot_id",
                      timeout=120,
                  ).strip()
                  assert boot_id, "the installed system must expose a boot ID"
                  images = machine.succeed(
                      "find /root/project/.data/image-references -maxdepth 1 "
                      "-name '*.qcow2' -print"
                  ).splitlines()
                  assert images, "the cached fixture must have image references"
                  for image in images:
                      machine.succeed(
                          "test " + shlex.quote(image)
                          + ' -ef /root/project/.data/$(cat /etc/machine-id)/test-machine/qemu/'
                          + shlex.quote(image.rsplit("/", 1)[-1])
                      )
                  check_guest_swap()
                  machine.succeed(shell + "ssh vm-test-machine " + shlex.quote(
                      "printf 'survived reboot' > /persist/reboot-marker && sync && "
                      "test \"$(cat /persist/reboot-marker)\" = 'survived reboot'"
                  ), timeout=120)

              with subtest("reboot the guest and unlock its disks automatically again"):
                  machine.succeed(shell + "ssh vm-test-machine reboot", timeout=120)
                  guest_checks = (
                      'current_boot_id=$(cat /proc/sys/kernel/random/boot_id) && '
                      'test -n "$current_boot_id" && test "$current_boot_id" != '
                      + shlex.quote(boot_id)
                      + ' && test "$(hostname)" = test-machine'
                      + ' && test "$(cat /persist/reboot-marker)" = "survived reboot" && sync'
                  )
                  after_reboot = "ssh vm-test-machine " + shlex.quote(guest_checks)
                  machine.wait_until_succeeds(
                      shell + "bash -ec " + shlex.quote(after_reboot),
                      timeout=900,
                  )
                  check_guest_swap()

              with subtest("stop the guest before exporting its disks"):
                  machine.succeed(shell + "idr process stop vm-test-machine", timeout=120)
                  stopped = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and (.[0].is_running | not)'"
                  )
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(stopped), timeout=120,
                  )
          except Exception:
              if daemon_started:
                  print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
              raise
          finally:
              if daemon_started:
                  machine.succeed(shell + "idr down", timeout=120)
                  machine.wait_until_succeeds(
                      shell + "bash -c " + shlex.quote(
                          "idr process get vm-test-machine -o json; status=$?; "
                          'test "$status" -gt 0 && test "$status" -lt 124'
                      ), timeout=60,
                  )

          with subtest("export the stopped VM with its persistent reboot marker"):
              # The consumer uses these read-only disks as overlay backing images.
              machine.succeed(
                  "mkdir -p ${archiveDirectory}/images && "
                  'cp --reflink=auto --sparse=always /root/project/.data/'
                  '$(cat /etc/machine-id)/test-machine/qemu/*.qcow2 ${archiveDirectory}/images/',
                  timeout=600,
              )
              machine.succeed(
                  "find /root/project/.data -mindepth 1 -maxdepth 1 "
                  "! -name machine-host-key -exec rm -rf {} +"
              )
              machine.succeed(
                  "tar -C /root --exclude=project/.git --sparse --sort=name --mtime=@0 "
                  "--owner=1000 --group=1000 --numeric-owner -c project "
                  "> ${archiveDirectory}/project.tar",
                  timeout=600,
              )
        '';
      });
    };
  };
}

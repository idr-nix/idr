top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      installation-mount = import ./installation-mount.nix {inherit pkgs;};
      ${
        if pkgs.stdenv.hostPlatform.isLinux
        then "installation-mount-preservation"
        else null
      } = import ./installation-mount-preservation.nix {
        inherit pkgs;
        diskoModule = top.inputs.disko.nixosModules.disko;
      };

      installation-confirmations = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "installation-confirmations";

        testScript = ''
          import json
          import shlex
          import textwrap

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

          disks = json.loads(machine.succeed(
              "cd /root/project && nix --offline eval --json "
              ".#nixosConfigurations.test-machine.config.disko.devices.disk "
              "--apply 'disks: map (disk: disk.device) (builtins.attrValues disks)'"
          ))
          assert disks, "installation must have configured target disks"
          quoted_disks = " ".join(shlex.quote(disk) for disk in disks)
          fingerprint = textwrap.dedent(f"""
              cat /proc/sys/kernel/random/boot_id
              readlink /run/current-system
              sha256sum /persist/installation-test
              for disk in {quoted_disks}; do
                  dd if="$disk" bs=512 count=2048 status=none | sha256sum
                  sectors=$(blockdev --getsz "$disk")
                  dd if="$disk" bs=512 skip=$((sectors - 33)) count=33 status=none | sha256sum
                  lsblk --list --noheadings --paths --output NAME,FSTYPE "$disk" |
                      while read -r device type; do
                          if test "$type" = crypto_LUKS; then
                              cryptsetup luksDump --dump-json-metadata "$device" | sha256sum
                          fi
                      done
              done
          """)
          remote_fingerprint = "bash -o pipefail -ec " + shlex.quote(fingerprint)
          inspect = "timeout --kill-after=10s 120s ssh -n vm-test-machine " + shlex.quote(remote_fingerprint)
          readiness = (
              "idr process get vm-test-machine -o json | "
              "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
          )

          def refuse(expected, options):
              status, output = machine.execute(
                  shell + "bash -c " + shlex.quote(
                      "timeout --kill-after=10s 300s idr-anywhere vm-test-machine " + options + " 2>&1"
                  ), timeout=330,
              )
              assert 0 < status < 124, (status, output)
              assert expected in output, output
              assert machine.succeed(shell + inspect, timeout=150) == before, output
              return output

          daemon_started = False
          try:
              with subtest("start the installed machine with data to preserve"):
                  machine.succeed(shell + "timeout --kill-after=10s 600s idr -D", timeout=630)
                  daemon_started = True
                  machine.succeed(shell + "timeout --kill-after=10s 120s idr process start vm-test-machine", timeout=150)
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(readiness), timeout=900,
                  )
                  print(machine.execute(
                      shell + "timeout --kill-after=10s 120s idr process logs --tail 2000 vm-test-machine",
                      timeout=150,
                  ))
                  machine.succeed(
                      shell + "timeout --kill-after=10s 120s ssh -n vm-test-machine "
                      + shlex.quote('printf "keep this persisted data\\n" > /persist/installation-test && sync'),
                      timeout=150,
                  )
                  before = machine.succeed(shell + inspect, timeout=150)

              with subtest("noninteractive installation refuses all missing confirmations"):
                  for options in ["-n", ""]:
                      output = refuse("Missing confirmations: WIPE_ALL_DISKS,WIPE_NIXOS", options)
                      assert "Disks currently in use by nixos:" in output, output
                      for disk in disks:
                          assert disk in output, output

              with subtest("allowing a wipe still refuses to overwrite a running NixOS system"):
                  refuse("Missing confirmations: WIPE_NIXOS", "--allow WIPE_ALL_DISKS -n")
                  assert machine.succeed(
                      shell + "timeout --kill-after=10s 120s ssh -n vm-test-machine hostname", timeout=150,
                  ).strip() == "test-machine"
          except Exception:
              if daemon_started:
                  print(machine.execute(
                      shell + "timeout --kill-after=10s 120s idr process logs --tail 1000 vm-test-machine",
                      timeout=150,
                  ))
              raise
          finally:
              if daemon_started:
                  try:
                      machine.succeed(shell + "timeout --kill-after=10s 120s idr down", timeout=150)
                  finally:
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

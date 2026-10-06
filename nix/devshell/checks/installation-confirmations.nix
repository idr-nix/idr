top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      installation-confirmations = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

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

          # The checkout is unchanged throughout this refusal flow. Keep its
          # real CLI commands, SSH inspections, and readiness polling in one shell.
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
          readiness = r"""
              until idr process get vm-test-machine -o json | jq -e 'length == 1 and .[0].is_running and .[0].is_ready == "Ready"'; do
                  sleep 1
              done
          """
          stopped = "while idr process get vm-test-machine -o json; do sleep 1; done"
          commands = rf"""
              set -o pipefail
              phase() {{
                  printf 'installation phase: %s elapsed=%ss %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SECONDS" "$*" >&2 || true
              }}
              phase shell-entry
              cleanup() {{
                  local status=$?
                  trap - EXIT
                  phase cleanup-begin
                  if test "$status" -ne 0; then
                      timeout --kill-after=10s 120s idr process logs --tail 1000 vm-test-machine || true
                  fi
                  timeout --kill-after=10s 120s idr down || status=1
                  timeout --kill-after=10s 60s bash -ec {shlex.quote(stopped)} || status=1
                  phase cleanup-finished
                  exit "$status"
              }}
              phase daemon-start
              echo 'start the installed machine with data to preserve'
              timeout --kill-after=10s 600s idr -D
              trap cleanup EXIT
              phase daemon-started
              phase vm-start
              timeout --kill-after=10s 120s idr process start vm-test-machine
              phase vm-started
              timeout --kill-after=10s 900s bash -o pipefail -ec {shlex.quote(readiness)}
              phase vm-ready
              timeout --kill-after=10s 120s idr process logs --tail 2000 vm-test-machine >&2 || true
              timeout --kill-after=10s 120s ssh -n vm-test-machine 'printf "keep this persisted data\n" > /persist/installation-test && sync'

              phase fingerprint-before
              before=$({inspect})
              phase fingerprint-captured
              disks=({quoted_disks})
              refuse() {{
                  local expected="$1" status
                  shift
                  phase "refusal-begin $*"
                  if output=$(timeout --kill-after=10s 300s idr-anywhere vm-test-machine "$@" 2>&1); then
                      printf '%s\n' "$output"
                      return 1
                  else
                      status=$?
                  fi
                  phase "refusal-returned $*"
                  if test "$status" -eq 124 || test "$status" -eq 137; then
                      printf 'installation refusal timed out (status %s)\n' "$status" >&2
                      printf '%s\n' "$output" >&2
                      return 1
                  fi
                  printf '%s\n' "$output"
                  grep -F -- "$expected" <<< "$output"
              }}
              echo 'noninteractive installation refuses all missing confirmations'
              for options in '-n' ""; do
                  if test -n "$options"; then
                      refuse 'Missing confirmations: WIPE_ALL_DISKS,WIPE_NIXOS' "$options"
                  else
                      refuse 'Missing confirmations: WIPE_ALL_DISKS,WIPE_NIXOS'
                  fi
                  grep -F 'Disks currently in use by nixos:' <<< "$output"
                  for disk in "''${{disks[@]}}"; do
                      grep -F -- "$disk" <<< "$output"
                  done
                  phase fingerprint-after-refusal
                  after=$({inspect})
                  test "$after" = "$before"
                  phase fingerprint-unchanged
              done

              echo 'allowing a wipe still refuses to overwrite a running NixOS system'
              refuse 'Missing confirmations: WIPE_NIXOS' --allow WIPE_ALL_DISKS -n
              phase fingerprint-after-refusal
              after=$({inspect})
              test "$after" = "$before"
              phase fingerprint-unchanged
              hostname=$(timeout --kill-after=10s 120s ssh -n vm-test-machine hostname)
              test "$hostname" = test-machine
          """
          with subtest("installation confirmations preserve the running machine"):
              machine.succeed(
                  "cd /root/project && nix --offline develop -c bash -ec " + shlex.quote(textwrap.dedent(commands)),
                  timeout=1800,
              )
        '';
      });
    };
  };
}

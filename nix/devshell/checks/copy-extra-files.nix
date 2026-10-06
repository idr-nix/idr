top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      copy-extra-files = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        name = "copy-extra-files";
        # Python executes harness assertions; the project store seed stays #default.
        defaults = {pkgs, ...}: {
          environment.systemPackages = [pkgs.python3];
        };

        testScript = ''
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

          def project(script, timeout):
              command = "cd /root/project && nix --offline develop -c bash -e -o pipefail -c "
              return machine.succeed(command + shlex.quote(textwrap.dedent(script)), timeout=timeout)

          destination = "/persist/var/lib/idr/copy-extra-files-test"
          quoted_destination = shlex.quote(destination)
          stopped = "while idr process get vm-test-machine -o json; do sleep 1; done"
          cleanup = rf"""
              cleanup() {{
                  local status=$?
                  trap - EXIT
                  if test "$status" -ne 0; then
                      timeout --kill-after=10s 120s idr process logs --tail 1000 vm-test-machine || true
                  fi
                  timeout --kill-after=10s 120s idr down || status=1
                  timeout --kill-after=10s 60s bash -ec {shlex.quote(stopped)} || status=1
                  exit "$status"
              }}
          """
          daemon_started = False
          try:
              with subtest("start the VM from the exported images"):
                  readiness = r"""
                      until idr process get vm-test-machine -o json | jq -e 'length == 1 and .[0].is_running and .[0].is_ready == "Ready"'; do
                          sleep 1
                      done
                  """
                  # This initial checkout is unchanged throughout startup.
                  project(cleanup + f"""
                      timeout --kill-after=10s 600s idr -D
                      trap cleanup EXIT
                      timeout --kill-after=10s 120s idr process start vm-test-machine
                      timeout --kill-after=10s 900s bash -o pipefail -ec {shlex.quote(readiness)}
                      trap - EXIT
                  """, timeout=1800)
                  daemon_started = True

              with subtest("add an encrypted post-format file and copy it to the running VM"):
                  configuration = "nix/machine/test-machine/configuration.nix"
                  edit = f'/networking.hostName =/a\\      idr.preset.base.postFormatFiles."{destination}".key = "copy_test";'
                  machine.succeed(
                      "cd /root/project && sed -i " + shlex.quote(edit) + " " + configuration
                      + " && git add " + configuration
                  )
                  project(
                      "sops set nix/machine/test-machine/secrets.enc.json "
                      + shlex.quote('["copy_test"]') + " " + shlex.quote('"first value"'),
                      timeout=120,
                  )
                  # Re-enter after the secret edit, then keep copy and its SSH
                  # assertions together in this unchanged checkout.
                  project(f"""
                      timeout --kill-after=10s 600s idr-copy-extra-files vm-test-machine
                      timeout --kill-after=10s 120s ssh -n vm-test-machine cat {quoted_destination} > /tmp/copied-contents
                      timeout --kill-after=10s 120s ssh -n vm-test-machine stat -c %u:%g:%a {quoted_destination} > /tmp/copied-mode
                  """, timeout=900)
                  contents = machine.succeed("cat /tmp/copied-contents").strip()
                  mode = machine.succeed("cat /tmp/copied-mode").strip()
                  assert contents == "first value", contents
                  assert mode == "0:0:600", mode

              with subtest("copy changed contents"):
                  project(
                      "sops set nix/machine/test-machine/secrets.enc.json "
                      + shlex.quote('["copy_test"]') + " " + shlex.quote('"updated value"'),
                      timeout=120,
                  )
                  # Re-enter after the updated secret, then retain this shell
                  # through both copies, their assertions, and daemon shutdown.
                  metadata_command = f"timeout --kill-after=10s 120s ssh -n vm-test-machine stat -c %i:%y {quoted_destination}"
                  updated_assertions = textwrap.dedent(r"""
                      from pathlib import Path
                      contents = Path("/tmp/copied-contents").read_text().strip()
                      mode = Path("/tmp/copied-mode").read_text().strip()
                      assert contents == "updated value", contents
                      assert mode == "0:0:600", mode
                  """)
                  unchanged_assertions = textwrap.dedent(f"""
                      from pathlib import Path
                      output = Path("/tmp/copy-unchanged-output").read_text()
                      assert any(
                          line.startswith("Unchanged: ") and line.endswith(":" + {destination!r})
                          for line in output.splitlines()
                      ), output
                      before = Path("/tmp/copy-before").read_text()
                      after = Path("/tmp/copy-after").read_text()
                      assert after == before, (before, after)
                  """)
                  project(cleanup + f"""
                      trap cleanup EXIT
                      timeout --kill-after=10s 600s idr-copy-extra-files vm-test-machine
                      timeout --kill-after=10s 120s ssh -n vm-test-machine cat {quoted_destination} > /tmp/copied-contents
                      timeout --kill-after=10s 120s ssh -n vm-test-machine stat -c %u:%g:%a {quoted_destination} > /tmp/copied-mode
                      /run/current-system/sw/bin/python3 -c {shlex.quote(updated_assertions)}
                      # Inode and subsecond mtime detect replacement even during the same second.
                      {metadata_command} > /tmp/copy-before
                      echo 'leave unchanged contents in place on the next copy'
                      timeout --kill-after=10s 600s idr-copy-extra-files vm-test-machine > /tmp/copy-unchanged-output
                      cat /tmp/copy-unchanged-output
                      {metadata_command} > /tmp/copy-after
                      /run/current-system/sw/bin/python3 -c {shlex.quote(unchanged_assertions)}
                  """, timeout=1800)
                  daemon_started = False
          except Exception:
              if daemon_started:
                  print(machine.execute(
                      "cd /root/project && nix --offline develop -c "
                      "timeout --kill-after=10s 120s idr process logs --tail 1000 vm-test-machine",
                      timeout=150,
                  ))
              raise
          finally:
              if daemon_started:
                  project(f"""
                      timeout --kill-after=10s 120s idr down
                      timeout --kill-after=10s 60s bash -ec {shlex.quote(stopped)}
                  """, timeout=210)
        '';
      });
    };
  };
}

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

        idr.test.direnv.offline = true;
        name = "copy-extra-files";

        testScript = ''
          import shlex

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

          def project(command, timeout):
              return machine.succeed(shell + command, timeout=timeout)

          def remote(command):
              return "timeout --kill-after=10s 120s ssh -n vm-test-machine " + shlex.quote(command)

          destination = "/persist/var/lib/idr/copy-extra-files-test"
          quoted_destination = shlex.quote(destination)
          copied_state = "bash -e -o pipefail -c " + shlex.quote(
              f"cat {quoted_destination}; printf '\\n'; stat -c %u:%g:%a {quoted_destination}"
          )
          metadata_command = remote(f"stat -c %i:%y {quoted_destination}")

          def assert_copied(expected):
              contents, mode = project(remote(copied_state), timeout=150).rsplit("\n", 2)[:2]
              assert contents.strip() == expected, contents
              assert mode.strip() == "0:0:600", mode

          daemon_started = False
          try:
              with subtest("start the VM from the exported images"):
                  project("timeout --kill-after=10s 600s idr -D", timeout=630)
                  daemon_started = True
                  project("timeout --kill-after=10s 120s idr process start vm-test-machine", timeout=150)
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(
                          "idr process get vm-test-machine -o json | "
                          "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                      ), timeout=900,
                  )

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
                  project("timeout --kill-after=10s 600s idr-copy-extra-files vm-test-machine", timeout=630)
                  assert_copied("first value")

              with subtest("copy changed contents"):
                  project(
                      "sops set nix/machine/test-machine/secrets.enc.json "
                      + shlex.quote('["copy_test"]') + " " + shlex.quote('"updated value"'),
                      timeout=120,
                  )
                  project("timeout --kill-after=10s 600s idr-copy-extra-files vm-test-machine", timeout=630)
                  assert_copied("updated value")

              with subtest("leave unchanged contents in place on the next copy"):
                  # Inode and subsecond mtime detect replacement even during the same second.
                  before = project(metadata_command, timeout=150)
                  output = project("timeout --kill-after=10s 600s idr-copy-extra-files vm-test-machine", timeout=630)
                  assert any(
                      line.startswith("Unchanged: ") and line.endswith(":" + destination)
                      for line in output.splitlines()
                  ), output
                  after = project(metadata_command, timeout=150)
                  assert after == before, (before, after)
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
                      project("timeout --kill-after=10s 120s idr down", timeout=150)
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

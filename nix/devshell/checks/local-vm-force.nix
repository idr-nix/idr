top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.local-vm-reboot;
  in {
    checks = {
      local-vm-force = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        inherit (pkgs.stdenv.hostPlatform) isDarwin;
        # Poll less frequently while nested QEMU uses TCG on Darwin.
        pollExpression = predicate: ''"until " + ${predicate} + "; do sleep ${
            if isDarwin
            then "5"
            else "1"
          }; done"'';
        example = top.self.nixosConfigurations."example-${system}".config;
        networkPrefix = example.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {
            inherit top project system;
            useBackingImages = true;
          })
        ];
        idr.test.direnv.offline = true;
        name = "local-vm-force";
        globalTimeout = lib.mkForce ((
            if isDarwin
            then 90
            else 45
          )
          * 60);

        defaults = {pkgs, ...}: {
          environment.systemPackages = [pkgs.qemu];
          programs.ssh = {
            knownHosts.vm-test-machine.publicKey = example.system.build.idr.meta.sshHostPublicKey;
            # Poll only the installed system; initrd SSH uses a different host key.
            extraConfig = lib.mkBefore ''
              Host vm-test-machine
                HostKeyAlias vm-test-machine
                StrictHostKeyChecking yes
            '';
          };
        };

        testScript = ''
          import json
          import shlex

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          shell = "cd /root/project && direnv exec . "
          machine.succeed("cd /root/project && direnv allow")
          runner_started = False
          try:
              with subtest("preserve the prepared disk overlays before forcing a rebuild"):
                  machine.succeed(
                      "cd /root/project && bash -ec '"
                      'image_cache=".data/$(cat /etc/machine-id)/test-machine/qemu"; '
                      'for image in .data/image-references/*.qcow2; do '
                      'test "$image" -ef "$image_cache/$(basename "$image")"; '
                      "done'"
                  )

              with subtest("force new images using the standalone runner"):
                  # A separate session supplies the foreground runner's terminal lifecycle.
                  # Leave room for two disk formatters and the builder's OS.
                  machine.succeed(shell + "bash -ec " + shlex.quote(
                      "env IDR_QEMU_BUILD_MEMORY=unused-because-cli-wins setsid nix --offline -L run .#vm-test-machine -- --force --build-memory 8192 "
                      "> /tmp/forced-vm.log 2>&1 < /dev/null & echo $! > /tmp/forced-vm.pid"
                  ), timeout=600)
                  runner_started = True
                  rebuilt = (
                      "ssh vm-test-machine 'test ! -e /persist/reboot-marker && "
                      "test \"$(hostname)\" = test-machine'"
                  )
                  machine.succeed(
                      shell + "bash -o pipefail -c " + shlex.quote(${pollExpression "rebuilt"}),
                      timeout=${
            if isDarwin
            then "3600"
            else "1800"
          },
                  )

          except Exception:
              print(machine.execute("tail -n 150 /tmp/forced-vm.log"))
              raise
          finally:
              if runner_started:
                  machine.execute("kill -TERM -- -$(cat /tmp/forced-vm.pid)")
                  machine.wait_until_succeeds(
                      "! kill -0 -- -$(cat /tmp/forced-vm.pid)", timeout=60,
                  )

          machine.copy_from_machine("/tmp/forced-vm.log")
          with subtest("all image files were replaced"):
              machine.succeed(
                  "cd /root/project && bash -ec '"
                  'image_cache=".data/$(cat /etc/machine-id)/test-machine/qemu"; '
                  'for image in .data/image-references/*.qcow2; do '
                  'test -f "$image_cache/$(basename "$image")"; '
                  '! test "$image" -ef "$image_cache/$(basename "$image")"; '
                  "done'"
              )
          with subtest("forced images have no backing files"):
              images = machine.succeed(
                  "find /root/project/.data/$(cat /etc/machine-id)/test-machine/qemu "
                  "-maxdepth 1 -type f -name '*.qcow2' -print"
              ).splitlines()
              assert images, "the forced runner must create images"
              for image in images:
                  info = json.loads(machine.succeed("qemu-img info --output=json " + shlex.quote(image)))
                  assert info["format"] == "qcow2", info
                  assert not info.get("backing-filename"), info
        '';
      });
    };
  };
}

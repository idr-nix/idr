top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-remote-build = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
        unsignedInput = config.node.pkgs.runCommand "idr-remote-build-unsigned-input" {} ''
          printf %s 'built on destination' > "$out"
        '';
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "local-vm-remote-build";
        idr.test.storePaths = [unsignedInput];

        defaults = {pkgs, ...}: {
          systemd.services.idr-project-fixture = {
            path = [pkgs.gnused];
            # Provision the build dependencies as declared system dependencies.
            # The destination has no network substituters during the remote build.
            script = lib.mkAfter ''
              sed -i '/networking.hostName =/a\
                    system.extraDependencies = [top.inputs.idr.nixosConfigurations."example-${system}".config.system.build.toplevel.inputDerivation];\
                    nix.settings.substituters = lib.mkForce [];' project/nix/machine/test-machine/configuration.nix
              # Use an unsigned derivation output as a store source, preserving its
              # reference without copying it into a content-addressed flake source.
              cat > project/nix/machine/test-machine/remote-build-input.nix <<'NIX'
              builtins.appendContext "${unsignedInput}" {
                "${unsignedInput}" = {path = true;};
              }
              NIX
              git -C project add nix/machine/test-machine/configuration.nix nix/machine/test-machine/remote-build-input.nix
            '';
          };
        };

        testScript = ''
          import json
          import re
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
          daemon_started = False
          try:
              with subtest("start the local VM from the exported images"):
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  readiness = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                  )
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(readiness), timeout=900,
                  )

              with subtest("deploy the machine's declared offline build dependencies"):
                  machine.succeed(shell + "deploy -s .#vm-test-machine -- -L", timeout=900)

              with subtest("build and activate the next configuration on the destination"):
                  configuration = "nix/machine/test-machine/configuration.nix"
                  edit = (
                      '/networking.hostName =/a\\      '
                      'environment.etc."idr-remote-build".source = import ./remote-build-input.nix;'
                  )
                  machine.succeed(
                      "cd /root/project && sed -i " + shlex.quote(edit) + " " + configuration
                      + " && git add " + configuration
                  )
                  profile = machine.succeed(
                      "cd /root/project && nix --offline eval --raw "
                      ".#deploy.nodes.vm-test-machine.profiles.system.path",
                      timeout=120,
                  ).strip()
                  assert profile.startswith("/nix/store/"), profile
                  machine.succeed("test ! -e " + shlex.quote(profile))
                  machine.succeed(
                      shell + "ssh vm-test-machine test ! -e " + shlex.quote(profile), timeout=120,
                  )

              with subtest("explicit signature checking rejects a fresh unsigned build input"):
                  unsigned_input = "${unsignedInput}"
                  metadata = json.loads(machine.succeed(
                      "nix path-info --json " + shlex.quote(unsigned_input)
                  ))[unsigned_input]
                  assert not metadata.get("ca") and not metadata.get("signatures"), metadata
                  machine.succeed(
                      shell + "ssh vm-test-machine test ! -e " + shlex.quote(unsigned_input), timeout=120,
                  )
                  status, failure = machine.execute(
                      shell + "bash -c " + shlex.quote(
                          "deploy -s --remote-build --checksigs .#vm-test-machine -- -L 2>&1"
                      ),
                      timeout=1200,
                  )
                  assert 0 < status < 124, (status, failure)
                  rejected = re.search(
                      r"cannot add path '(/nix/store/[^']+)' because it lacks a signature", failure,
                  )
                  assert rejected, failure
                  # This copy has never succeeded, so the strict check cannot be
                  # bypassed by an input already present on the destination.
                  machine.succeed(
                      shell + "ssh vm-test-machine test ! -e " + shlex.quote(rejected.group(1)), timeout=120,
                  )

              with subtest("the default signature policy permits the remote build"):
                  machine.succeed(
                      shell + "deploy -s --remote-build .#vm-test-machine -- -L", timeout=1200,
                  )
                  remote_verification = (
                      "set -e; "
                      "content=$(cat /etc/idr-remote-build); "
                      "profile=$(readlink -f /nix/var/nix/profiles/system); "
                      "printf '%s\\n%s\\n' \"$content\" \"$profile\""
                  )
                  deployed_content, deployed_profile = machine.succeed(
                      shell + "ssh vm-test-machine " + shlex.quote(remote_verification),
                      timeout=120,
                  ).split("\n", 1)
                  assert deployed_content.strip() == "built on destination"
                  assert deployed_profile.strip() == profile
                  # An ordinary local deployment would have built this output here.
                  machine.succeed("test ! -e " + shlex.quote(profile))
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

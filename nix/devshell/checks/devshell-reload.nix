top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    reloadTest = upstream:
      pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (pkgs.stdenv.hostPlatform) isLinux;
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
      in {
        imports = with top.self.modules.nixosTest; [base operator];

        name = "devshell-reload${lib.optionalString upstream "-upstream"}";
        globalTimeout = 20 * 60;

        idr.test.storePaths = [top.self.packages.${system}.default];

        defaults = {pkgs, ...}: {
          nix = lib.mkIf upstream {
            package = lib.mkForce pkgs.nix;
            settings = lib.mkForce {
              experimental-features = ["nix-command" "flakes"];
              sandbox = true;
              sandbox-fallback = false;
              substituters = [];
              trusted-users = ["root"];
              build-users-group = lib.optionalString (!isLinux) "nixbld";
            };
          };
          systemd.services.idr-project-fixture = {
            description = "Restore the mk-project archive";
            wantedBy = ["multi-user.target"];
            after = ["systemd-tmpfiles-setup.service"];
            path = [pkgs.gnutar pkgs.gitMinimal];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "operator";
              Group = "operator";
              WorkingDirectory = "/home/operator";
            };
            script = ''
              tar -xf ${project}/project.tar
              git -C project init -q
              git -C project add -A
            '';
          };
        };

        containers = lib.optionalAttrs isLinux {machine = {};};

        nodes = lib.optionalAttrs (!isLinux) {
          machine = {
            virtualisation = {
              memorySize = 8192;
              cores = 8;
            };
            networking.useDHCP = false;
          };
        };

        testScript = ''
          import json
          import shlex

          def operator(command, timeout=900):
              return machine.succeed(
                  "su - operator -c " + shlex.quote("cd project && " + command),
                  timeout=timeout,
              )

          start_all()
          machine.wait_for_unit("idr-project-fixture.service")
          host_id = operator("cat /etc/machine-id").strip()
          roots_directory = "/home/operator/project/.data/" + host_id + "/gcroot"
          temporary_directory = "/home/operator/project/.data/" + host_id + "/tmp"
          expected_roots = json.loads(operator(
              "nix --offline eval --json .#packages.${system}.default.passthru.deps --apply "
              + shlex.quote("builtins.mapAttrs (_: builtins.toString)")
          ))
          assert set(expected_roots) == {"documentation-inputs", "example-machine", "nixos-image"}, expected_roots

          def gcroots():
              registered = [shlex.split(line) for line in machine.succeed("nix-store --gc --print-roots").splitlines()]
              targets = {}
              for name in expected_roots:
                  root = roots_directory + "/" + name
                  target = operator("readlink -e -- " + shlex.quote(root)).strip()
                  assert [root, "->", target] in registered, (root, target, registered)
                  targets[name] = target
              return targets

          with subtest("enter the development shell to warm the Nix cache"):
              operator("direnv allow")
              environment_checks = (
                  'test "$IDR_GCROOT" = ' + shlex.quote(roots_directory) + '; '
                  'test "$IDR_TMPDIR" = ' + shlex.quote(temporary_directory) + '; '
                  'test "$TMPDIR" = ' + shlex.quote(temporary_directory) + '; '
                  'test "$TMP" = "$TMPDIR"; test "$TEMP" = "$TMPDIR"; '
                  'test -d "$IDR_GCROOT"; test -d "$TMPDIR"; '
                  'temporary=$(mktemp); test "''${temporary%/*}" = "$TMPDIR"; rm -- "$temporary"; '
                  '"$IDR_BACKGROUND_BUILD" wait'
              )
              operator("direnv exec . bash -exc " + shlex.quote(environment_checks))
              original_roots = gcroots()
              assert original_roots == expected_roots, original_roots

          with subtest("re-enter the cached shell within five seconds"):
              operator("timeout --kill-after=2s 5s direnv exec . true", timeout=10)
              assert gcroots() == original_roots

          with subtest("edit the project description"):
              operator("sed -i 's/^  description = .*/  description = \"Reloaded development environment\";/' flake.nix")
              operator("grep -Fx '  description = \"Reloaded development environment\";' flake.nix")

          with subtest("reload the development shell within fifteen seconds"):
              operator("timeout --kill-after=3s 15s direnv exec . true", timeout=20)
              assert gcroots() == original_roots

          with subtest("restore missing and stale dependency roots offline"):
              operator("rm -- " + shlex.quote(roots_directory + "/example-machine"))
              operator(
                  "ln -sfn -- " + shlex.quote(original_roots["example-machine"]) + " "
                  + shlex.quote(roots_directory + "/nixos-image")
              )
              operator("direnv exec . bash -ec " + shlex.quote(
                  '"$IDR_BACKGROUND_BUILD" wait ' + " ".join(map(shlex.quote, expected_roots))
              ))
              assert gcroots() == original_roots
        '';
      });
  in {
    checks = {
      devshell-reload = reloadTest false;
      devshell-reload-upstream = reloadTest true;
    };
  };
}

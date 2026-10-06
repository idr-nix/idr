top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.mk-project-existing-flake = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      devshell = top.self.packages.${config.node.pkgs.stdenv.hostPlatform.system}.default;
      fixture = ./fixtures/existing-flake;
      lock = builtins.fromJSON (builtins.readFile (top.self + "/flake.lock"));
      existingLock = pkgs.writeText "existing-flake.lock" (builtins.toJSON (lock
        // {
          nodes =
            lock.nodes
            // {
              root =
                lock.nodes.root
                // {
                  inputs = lib.filterAttrs (name: _: builtins.elem name ["nixpkgs" "nixpkgs-unstable" "flake-parts" "systems" "team"]) lock.nodes.root.inputs;
                };
            };
        }));
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator ssh-git];

      name = "mk-project-existing-flake";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [devshell];
      idr.test.sshGit.repositories = [
        {
          source = top.self;
          url = "git+ssh://git@github.com/idr-nix/idr";
        }
      ];

      defaults = {pkgs, ...}: {
        systemd.services.idr-existing-project-fixture = {
          description = "Prepare an existing flake with the README's IDR integration";
          wantedBy = ["multi-user.target"];
          after = ["systemd-tmpfiles-setup.service"];
          path = [pkgs.coreutils pkgs.gitMinimal];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "operator";
            Group = "operator";
            WorkingDirectory = "/home/operator";
          };
          script = ''
            cp -r --no-preserve=mode ${fixture} project
            mkdir project/nix
            cp ${existingLock} project/flake.lock
            chmod u+w project/flake.lock
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
        start_all()
        machine.wait_for_unit("sshd.service")
        machine.wait_for_unit("idr-existing-project-fixture.service")

        with subtest("initialize the existing flake following the README"):
            machine.succeed(
                "su - operator -c 'cd project && "
                "nix run \"git+ssh://git@github.com/idr-nix/idr\" -- idr-mk-project .'",
                timeout=900,
            )

        with subtest("preserve existing configuration and environment files"):
            machine.succeed(
                "su - operator -c 'cd project && "
                "cmp flake.nix ${fixture}/flake.nix && "
                "cmp existing-module.nix ${fixture}/existing-module.nix && "
                "cmp .env ${fixture}/.env && cmp .envrc ${fixture}/.envrc && "
                "test \"$(nix eval --raw .#preservedCallback)\" = existing:module && "
                "nix build .#existing && test \"$(cat result)\" = kept'",
                timeout=600,
            )

        with subtest("load the existing environment in the development shell"):
            machine.succeed(
                "su - operator -c 'cd project && bash -e' <<'COMMANDS'\n"
                "nix develop -c bash -ec 'test \"$EXISTING_ENV\" = \"kept value\"; command -v idr-mk-machine'\n"
                "COMMANDS",
                timeout=900,
            )
      '';
    });
  };
}

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.team-input = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
      machineId = top.self.nixosConfigurations."example-${system}".config.idr.preset.base.id;
      team = {
        John = {
          firstName = "John";
          lastName = "Doe";
          uidNumber = 5000;
          gidNumber = 5000;
          mail = "john@example.invalid";
          sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEjuIF2uXOUQyThLB6O5jmHCcz11uokg9XCAot+XHzM3";
          agePublicKey = "age1qe5lxzzeppw5k79vxn3872272sgy224g2nzqlzy3uljs84say3yqgvd0sw";
          groups = ["concourse_users"];
          department = "operations";
          sshAccess."test-machine-${machineId}" = {};
        };
        Other = {
          sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsWVu+D+kh5+H3bFWqcqF8M5QPB9eB9nny5QJn29a+1";
          sshAccess."other-machine-${machineId}" = {};
        };
      };
      teamFile = (pkgs.formats.toml {}).generate "team.toml" team;
      teamSource = pkgs.runCommand "team-repository" {} ''
        mkdir "$out"
        cp ${teamFile} "$out/team.toml"
      '';
      teamModule = pkgs.writeText "team-flake-module.nix" ''
        top: _: {
          flake.testTeam = top.idr-lib.team;
        }
      '';
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator ssh-git];

      name = "team-input";
      globalTimeout = 15 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];
      idr.test.sshGit.repositories = [
        {
          source = top.self;
          url = "git+ssh://git@github.com/idr-nix/idr";
        }
        {
          source = teamSource;
          url = "git+ssh://git@github.com/myorg/team";
        }
      ];

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with the documented team input";
          wantedBy = ["multi-user.target"];
          after = ["systemd-tmpfiles-setup.service"];
          path = [pkgs.coreutils pkgs.gnutar pkgs.gnused pkgs.gitMinimal];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "operator";
            Group = "operator";
            WorkingDirectory = "/home/operator";
          };
          script = ''
            tar -xf ${project}/project.tar
            sed -i 's|file+file:///dev/null|git+ssh://git@github.com/myorg/team|' project/flake.nix
            mkdir -p project/nix/team
            cp ${teamModule} project/nix/team/flake-module.nix
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

        start_all()
        machine.wait_for_unit("sshd.service")
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("update the team input following the documentation"):
            machine.succeed(
                "su - operator -c 'cd project && nix flake update team'",
                timeout=600,
            )

        with subtest("read team members and custom fields from a flake module"):
            members = json.loads(machine.succeed(
                "su - operator -c 'cd project && nix eval --no-update-lock-file --json .#testTeam'",
                timeout=600,
            ))
            assert members == json.loads(r"""${builtins.toJSON team}"""), members

        with subtest("authorize only the member granted access to this machine"):
            key_files = json.loads(machine.succeed(
                "su - operator -c 'cd project && nix eval --no-update-lock-file --json "
                ".#nixosConfigurations.test-machine.config.users.users.root.openssh.authorizedKeys.keyFiles "
                "--apply \"files: map builtins.readFile files\"'",
                timeout=600,
            ))
            keys = [key for contents in key_files for key in contents.splitlines()]
            assert keys == ["${team.John.sshPublicKey}"], keys
      '';
    });
  };
}

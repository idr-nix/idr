top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    projectFiles = ./fixtures/generated-post-write/flake-module.nix;
  in {
    checks.generated-project-files-post-write = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "generated-project-files-post-write";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with the documented postWrite renderer";
          wantedBy = ["multi-user.target"];
          after = ["systemd-tmpfiles-setup.service"];
          path = [pkgs.coreutils pkgs.gnutar pkgs.gitMinimal];
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
            mkdir project/nix/project-files
            cp --no-preserve=mode ${projectFiles} project/nix/project-files/flake-module.nix
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

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")
        operator("direnv allow")

        with subtest("render the application configuration after writing its template"):
            operator("git add nix/project-files/flake-module.nix")
            operator("direnv exec . true")
            rendered = json.loads(machine.succeed("cat /home/operator/project/.data/example-app.json"))
            assert rendered == {
                "logLevel": "info",
                "dataDir": "/home/operator/project/.data/example-app",
            }, rendered

        with subtest("changing the environment alone does not rerun postWrite"):
            operator('PRJ_DATA_DIR="$PWD/alternate-data" direnv exec . true')
            operator("test ! -e alternate-data/example-app.json")

        with subtest("changing the template reruns postWrite using the current environment"):
            operator("sed -i s/info/debug/ nix/project-files/flake-module.nix")
            operator('PRJ_DATA_DIR="$PWD/alternate-data" direnv exec . true')
            rendered = json.loads(machine.succeed("cat /home/operator/project/alternate-data/example-app.json"))
            assert rendered == {
                "logLevel": "debug",
                "dataDir": "/home/operator/project/alternate-data/example-app",
            }, rendered
            template = json.loads(machine.succeed("cat /home/operator/project/.data/example-app.template.json"))
            assert template == {"logLevel": "debug"}, template
      '';
    });
  };
}

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    projectFiles = pkgs.writeText "project-files-flake-module.nix" ''
      _: {
        perSystem = {pkgs, ...}: {
          idr.files = {
            ".editorconfig".content = '''
              root = true

              [*]
              indent_style = space
              indent_size = 2
            ''';
            ".config/example-app.json" = {
              content = pkgs.writers.writeJSON "example-app.json" {
                logLevel = "info";
              };
              copy = true;
            };
          };
        };
      }
    '';
  in {
    checks.generated-project-files = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "generated-project-files";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with the documented generated files";
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
            cp ${projectFiles} project/nix/project-files/flake-module.nix
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

        def assert_generated_files():
            machine.succeed(
                "test -L /home/operator/project/.editorconfig && "
                "test -f /home/operator/project/.config/example-app.json && "
                "test ! -L /home/operator/project/.config/example-app.json"
            )
            target = machine.succeed("readlink /home/operator/project/.editorconfig").strip()
            assert target.startswith("/nix/store/"), target
            editorconfig = machine.succeed("cat /home/operator/project/.editorconfig")
            assert editorconfig == "root = true\n\n[*]\nindent_style = space\nindent_size = 2\n", editorconfig
            config = json.loads(machine.succeed("cat /home/operator/project/.config/example-app.json"))
            assert config == {"logLevel": "info"}, config

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")
        operator("direnv allow")

        with subtest("generate a store symlink and a copied JSON file following the documentation"):
            operator("git add nix/project-files/flake-module.nix")
            operator("direnv exec . true")
            assert_generated_files()

        with subtest("restore missing and modified files on the next shell entry"):
            operator("rm .editorconfig")
            operator("chmod u+w .config/example-app.json")
            operator("printf modified > .config/example-app.json")
            operator("direnv exec . true")
            assert_generated_files()
      '';
    });
  };
}

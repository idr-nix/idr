top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.development-git-hooks-check = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "development-git-hooks-check";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with the documented Alejandra flake check";
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
            mkdir project/nix/formatting
            cp --no-preserve=mode ${./fixtures/development-git-hooks-check/flake-module.nix} project/nix/formatting/flake-module.nix
          '';
        };
      };

      containers = lib.optionalAttrs isLinux {machine = {};};

      nodes = lib.optionalAttrs (!isLinux) {
        machine = {
          virtualisation = {
            memorySize = 4096;
            cores = 4;
          };
          networking.useDHCP = false;
        };
      };

      testScript = ''
        import shlex

        def operator(command, *, succeeds=True):
            run = machine.succeed if succeeds else machine.fail
            return run(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("flake checks reject an unformatted tracked Nix file"):
            operator(
                "git add nix/formatting/flake-module.nix"
                " && printf '{ value=1; }\\n' > format-example.nix"
                " && git add format-example.nix"
            )
            operator("direnv allow")
            output = operator("nix flake check -L 2>&1", succeeds=False)
            assert "alejandra" in output.lower(), output
            assert "files were modified by this hook" in output, output
            assert "format-example.nix" in output, output
            assert operator("cat format-example.nix") == "{ value=1; }\n"

        with subtest("format the project and pass the same flake checks"):
            operator("direnv exec . pre-commit run --all-files", succeeds=False)
            assert "value = 1;" in operator("cat format-example.nix")
            operator("git add -u")
            operator("direnv exec . pre-commit run --all-files")
            operator("nix flake check -L")
      '';
    });
  };
}

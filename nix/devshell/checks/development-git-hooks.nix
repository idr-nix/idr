top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.development-git-hooks-commit = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "development-git-hooks-commit";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with the documented Alejandra hook";
          wantedBy = ["multi-user.target"];
          after = ["systemd-tmpfiles-setup.service"];
          path = [pkgs.coreutils pkgs.gnutar pkgs.gitMinimal pkgs.alejandra];
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
            cp --no-preserve=mode ${./fixtures/development-git-hooks/flake-module.nix} project/nix/formatting/flake-module.nix
            printf '{ value = 1; }\n' > project/format-example.nix
            alejandra project
            git -C project add -A
            git -C project commit -qm 'Enable formatting'
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
        import shlex

        def operator(command, *, succeeds=True):
            run = machine.succeed if succeeds else machine.fail
            return run(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("shell entry installs the documented commit hook"):
            operator("direnv allow")
            operator("direnv exec . true")
            operator("test -x .git/hooks/pre-commit")

        with subtest("a real commit runs the installed hook and requires staging its formatting changes"):
            previous = operator("git rev-parse HEAD").strip()
            operator("printf '{ value=2; }\\n' > format-example.nix && git add format-example.nix")
            output = operator("direnv exec . git commit -m 'Change value' 2>&1", succeeds=False)
            assert "alejandra" in output.lower(), output
            assert operator("git rev-parse HEAD").strip() == previous
            assert "value = 2;" in operator("cat format-example.nix")
            operator("git diff --exit-code -- format-example.nix", succeeds=False)
            operator("git add format-example.nix && direnv exec . git commit -m 'Change value'")
            assert operator("git rev-parse HEAD").strip() != previous
            assert "value = 2;" in operator("git show HEAD:format-example.nix")
            operator("git diff --exit-code HEAD -- format-example.nix")
      '';
    });
  };
}

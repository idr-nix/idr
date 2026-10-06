top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.development-shell-tools = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "development-shell-tools";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default] ++ (with config.node.pkgs; [curl git]);

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with the documented shell tools";
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
            printf 'A clean line\n' > project/patch.txt
            git -C project init -q
            git -C project add -A
            mkdir project/nix/shell-tools
            cp --no-preserve=mode ${./fixtures/development-shell-tools/flake-module.nix} project/nix/shell-tools/flake-module.nix
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

        with subtest("load the documented packages, environment and command"):
            operator("git add nix/shell-tools/flake-module.nix")
            operator("printf '\\nLOCAL_LABEL=local-$((2 + 3))\\n' >> .env")
            operator("nix develop -c bash -euc " + shlex.quote(
                'curl --version; test "$APP_ENV" = development; test "$LOCAL_LABEL" = local-5'
            ))
            assert "check-whitespace" in operator("nix develop -c menu")
            operator("nix develop -c check-whitespace")

        with subtest("the custom command reports invalid patch whitespace"):
            operator("printf 'A line with trailing spaces  \\n' > patch.txt")
            output = operator("nix develop -c check-whitespace", succeeds=False)
            assert "trailing whitespace" in output, output
            operator("printf 'A clean replacement\\n' > patch.txt")
            operator("nix develop -c check-whitespace")
      '';
    });
  };
}

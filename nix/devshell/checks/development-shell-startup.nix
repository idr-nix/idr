top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    mkCheck = mode:
      pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (pkgs.stdenv.hostPlatform) isLinux;
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
      in {
        imports = with top.self.modules.nixosTest; [nix nix-store operator];

        name = "development-shell-startup-${mode}";
        globalTimeout = 20 * 60;

        idr.test.storePaths = [top.self.packages.${system}.default];

        defaults = {pkgs, ...}: {
          programs.direnv.enable = true;
          systemd.services.idr-project-fixture = {
            description = "Restore the project archive with the documented shell startup action";
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
              mkdir project/nix/shell-startup
              cp --no-preserve=mode ${./fixtures/development-shell-startup/flake-module.nix} project/nix/shell-startup/flake-module.nix
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

        testScript =
          ''
            import shlex

            def operator(command):
                return machine.succeed(
                    "su - operator -c " + shlex.quote("cd project && " + command),
                    timeout=900,
                )

            start_all()
            machine.wait_for_unit("idr-project-fixture.service")
            operator("git add nix/shell-startup/flake-module.nix")
            operator("test ! -e .data/cache")

          ''
          + lib.optionalString (mode == "develop") ''
            with subtest("prepare the cache whenever the development shell is entered"):
                operator("nix develop -c bash -euc " + shlex.quote('test -d "$PRJ_DATA_DIR/cache"'))
                operator("rmdir .data/cache")
                operator("nix develop -c bash -euc " + shlex.quote('test -d "$PRJ_DATA_DIR/cache"'))

          ''
          + lib.optionalString (mode == "direnv") ''
            with subtest("run the startup action when direnv activates the shell"):
                machine.succeed(
                    "su - operator -c 'bash -ile' <<'COMMANDS'\n"
                    "cd project\n"
                    "direnv allow\n"
                    'test -d "$PRJ_DATA_DIR/cache"\n'
                    "exit\n"
                    "COMMANDS",
                    timeout=900,
                )
          '';
      });
  in {
    checks = {
      development-shell-startup-develop = mkCheck "develop";
      development-shell-startup-direnv = mkCheck "direnv";
    };
  };
}

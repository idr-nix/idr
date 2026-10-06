top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.development-shell-startup-ordering = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "development-shell-startup-ordering";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with a startup action that consumes a generated file";
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
            cp --no-preserve=mode ${./fixtures/development-shell-startup-ordering/flake-module.nix} project/nix/shell-startup/flake-module.nix
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

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("consume a generated file after idr-write-files on shell entry"):
            operator("git add nix/shell-startup/flake-module.nix")
            operator("test ! -e .config/startup-message && test ! -e .data/cache/startup-message")
            operator("nix develop -c true")
            assert operator("cat .data/cache/startup-message") == "Generated before the startup action\n"

        with subtest("restore the generated input before the action runs again"):
            operator("rm .config/startup-message .data/cache/startup-message")
            operator("nix develop -c true")
            assert operator("cat .data/cache/startup-message") == "Generated before the startup action\n"
      '';
    });
  };
}

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.devshell-reload = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "devshell-reload";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
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
        import shlex

        def operator(command, timeout=900):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=timeout,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("enter the development shell to warm the Nix cache"):
            operator("nix --offline develop -c true")

        with subtest("edit the project description"):
            operator("sed -i 's/^  description = .*/  description = \"Reloaded development environment\";/' flake.nix")
            operator("grep -Fx '  description = \"Reloaded development environment\";' flake.nix")

        with subtest("reload the development shell within two minutes"):
            operator("timeout --kill-after=5s 120s nix --offline develop -c true", timeout=130)
      '';
    });
  };
}

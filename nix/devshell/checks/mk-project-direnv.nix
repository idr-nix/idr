top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.mk-project-direnv = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "mk-project-direnv";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        programs.direnv.enable = true;
        systemd.tmpfiles.rules = [
          "d /home/operator/path 0755 operator operator -"
          "d /home/operator/path/to 0755 operator operator -"
        ];
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
            tar -C path/to -xf ${project}/project.tar
            git -C path/to/project init -q
            git -C path/to/project add -A
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
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("activate the project following the README"):
            machine.succeed(
                "su - operator -c 'bash -ile' <<'COMMANDS'\n"
                "cd path/to/project\n"
                "direnv allow\n"
                'test "$PRJ_ROOT" = "$PWD"\n'
                "command -v idr-mk-machine\n"
                "exit\n"
                "COMMANDS",
                timeout=900,
            )
      '';
    });
  };
}

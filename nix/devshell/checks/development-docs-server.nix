top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    localDocs = pkgs.writeText "local-docs-flake-module.nix" ''
      _: {
        perSystem = {pkgs, ...}: {
          process-compose.idr.settings.processes.docs-server.command =
            "''${pkgs.python3}/bin/python -m http.server 8080 --bind 127.0.0.1 --directory docs";
        };
      }
    '';
  in {
    checks.development-docs-server = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "development-docs-server";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        environment.systemPackages = [pkgs.curl];
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with the documented local docs server";
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
            mkdir -p project/docs
            printf 'Project documentation\n' > project/docs/index.html
            git -C project init -q
            git -C project add -A
            mkdir project/nix/local-docs
            cp --no-preserve=mode ${localDocs} project/nix/local-docs/flake-module.nix
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

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        daemon_started = False
        try:
            with subtest("load the documented module and start the local documentation server"):
                operator("git add nix/local-docs/flake-module.nix")
                operator("nix develop -c idr -D")
                daemon_started = True
                machine.wait_for_open_port(8080, addr="127.0.0.1", timeout=120)
                assert machine.succeed(
                    "curl --fail --silent --show-error http://127.0.0.1:8080/"
                ) == "Project documentation\n"

            with subtest("serve updates from the project's working directory"):
                operator("printf 'Updated documentation\\n' > docs/index.html")
                assert machine.succeed(
                    "curl --fail --silent --show-error http://127.0.0.1:8080/"
                ) == "Updated documentation\n"
        finally:
            if daemon_started:
                with subtest("stop the project and its documentation server"):
                    operator("nix develop -c idr down")
                    machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
      '';
    });
  };
}

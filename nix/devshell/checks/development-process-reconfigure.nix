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
          process-compose.idr.settings.processes.docs-server = {
            command = "''${pkgs.python3}/bin/python -m http.server 8080 --bind 127.0.0.1 --directory docs";
          };
        };
      }
    '';
  in {
    checks.development-process-reconfigure = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "development-process-reconfigure";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default config.node.pkgs.python3];

      defaults = {pkgs, ...}: {
        environment.systemPackages = [pkgs.curl];
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with the documented local server";
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
            mkdir -p project/docs project/nix/local-docs
            printf 'Project documentation\n' > project/docs/index.html
            git -C project init -q
            git -C project add -A
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

        def server_responds(port):
            machine.wait_for_open_port(port, addr="127.0.0.1", timeout=120)
            assert machine.succeed(
                f"curl --fail --silent --show-error http://127.0.0.1:{port}/"
            ) == "Project documentation\n"

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        daemon_started = False
        try:
            with subtest("start the documented server on its original port"):
                operator("git add nix/local-docs/flake-module.nix")
                operator("nix develop -c idr -D")
                daemon_started = True
                server_responds(8080)

            with subtest("reload edited process configuration by re-entering the shell and restarting IDR"):
                operator("sed -i 's/8080/8081/g' nix/local-docs/flake-module.nix")
                operator("nix develop -c idr down")
                daemon_started = False
                machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
                operator("nix develop -c idr -D")
                daemon_started = True
                server_responds(8081)
                machine.fail("curl --fail --silent --max-time 2 http://127.0.0.1:8080/")
        finally:
            if daemon_started:
                with subtest("stop the reconfigured project"):
                    operator("nix develop -c idr down")
                    machine.wait_for_closed_port(8081, addr="127.0.0.1", timeout=60)
                    machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
      '';
    });
  };
}

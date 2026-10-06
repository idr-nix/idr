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
    checks.development-process-logs = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "development-process-logs";
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

        daemon_started = False
        try:
            with subtest("start the server and follow its output"):
                operator("git add nix/local-docs/flake-module.nix")
                operator("nix develop -c bash -euc " + shlex.quote(
                    'idr -D; '
                    'idr process logs -f docs-server > "$PRJ_DATA_DIR/followed.log" 2>&1 & '
                    'echo $! > "$PRJ_DATA_DIR/follower.pid"'
                ))
                daemon_started = True
                machine.wait_for_open_port(8080, addr="127.0.0.1", timeout=120)
                machine.succeed("curl --fail --silent http://127.0.0.1:8080/index.html?first-request")
                machine.wait_until_succeeds(
                    "grep -F 'GET /index.html?first-request HTTP/1.1' /home/operator/project/.data/followed.log",
                    timeout=60,
                )

            with subtest("following logs delivers new output without restarting the viewer"):
                machine.succeed("curl --fail --silent http://127.0.0.1:8080/index.html?second-request")
                machine.wait_until_succeeds(
                    "grep -F 'GET /index.html?second-request HTTP/1.1' /home/operator/project/.data/followed.log",
                    timeout=60,
                )
        finally:
            if daemon_started:
                try:
                    operator('kill -TERM "$(cat .data/follower.pid)"')
                finally:
                    operator("nix develop -c idr down")
                    machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
      '';
    });
  };
}

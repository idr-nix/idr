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
    mkCheck = mode:
      pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (pkgs.stdenv.hostPlatform) isLinux;
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
      in {
        imports = with top.self.modules.nixosTest; [nix nix-store operator];

        name = "development-process-ui-${mode}";
        globalTimeout = 20 * 60;

        idr.test.storePaths = [top.self.packages.${system}.default config.node.pkgs.python3];

        defaults = {pkgs, ...}: {
          environment.systemPackages = [pkgs.curl (pkgs.python3.withPackages (ps: [ps.pexpect]))];
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

        testScript =
          ''
            ${lib.optionalString (mode == "attach") "import json"}
            import shlex

            def operator(command):
                return machine.succeed(
                    "su - operator -c " + shlex.quote("cd project && " + command),
                    timeout=900,
                )

            def interact(arguments, confirmation):
                script = f"""
            import os
            import subprocess
            import pexpect

            with pexpect.spawn(
                "nix", ["develop", "-c", "idr"] + {arguments!r},
                env=dict(os.environ, TERM="xterm-256color"),
                encoding="utf-8", dimensions=(40, 160), timeout=120,
            ) as terminal:
                terminal.expect_exact("docs-server")
                terminal.expect_exact("Running")
                response = subprocess.check_output([
                    "curl", "--fail", "--silent", "--retry", "60",
                    "--retry-connrefused", "--retry-delay", "1", "--retry-max-time", "60",
                    "--max-time", "2", "http://127.0.0.1:8080/"
                ], text=True)
                assert response == "Project documentation\\n", response
                terminal.sendcontrol("c")
                terminal.expect_exact({confirmation!r})
                terminal.send("\\r")
                terminal.expect(pexpect.EOF, timeout=60)
                terminal.close()
                assert terminal.exitstatus == 0, (terminal.exitstatus, terminal.signalstatus)
            """
                machine.succeed(
                    "su - operator -c " + shlex.quote("cd project && python -")
                    + " <<'PY'\n" + script + "\nPY",
                    timeout=900,
                )

            start_all()
            machine.wait_for_unit("idr-project-fixture.service")
            operator("git add nix/local-docs/flake-module.nix")

          ''
          + lib.optionalString (mode == "foreground") ''
            project_stopped = False
            try:
                with subtest("start idr in its terminal UI and quit the project"):
                    interact([], "Are you sure you want to quit?")
                    machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
                    project_stopped = True
            finally:
                if not project_stopped:
                    operator("nix develop -c idr down || true")
                    machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
          ''
          + lib.optionalString (mode == "attach") ''
            daemon_started = False
            try:
                with subtest("attach to a background project and detach without stopping it"):
                    operator("nix develop -c idr -D")
                    daemon_started = True
                    machine.wait_for_open_port(8080, addr="127.0.0.1", timeout=120)
                    before = json.loads(operator("nix develop -c idr process get docs-server -o json"))[0]
                    interact(["attach"], "Detach from the remote project?")
                    after = json.loads(operator("nix develop -c idr process get docs-server -o json"))[0]
                    assert after["is_running"] and after["pid"] == before["pid"], (before, after)
                    assert machine.succeed(
                        "curl --fail --silent http://127.0.0.1:8080/"
                    ) == "Project documentation\n"
            finally:
                if daemon_started:
                    operator("nix develop -c idr down")
                    machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
          '';
      });
  in {
    checks = {
      development-process-ui-foreground = mkCheck "foreground";
      development-process-ui-attach = mkCheck "attach";
    };
  };
}

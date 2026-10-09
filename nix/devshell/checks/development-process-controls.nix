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
            disabled = true;
          };
        };
      }
    '';
  in {
    checks.development-process-controls = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "development-process-controls";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        environment.systemPackages = [pkgs.curl];
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with a disabled documentation server";
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
        import json
        import shlex

        def operator(command, *, succeeds=True, timeout=900):
            run = machine.succeed if succeeds else machine.fail
            return run(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=timeout,
            )

        def server_state():
            states = json.loads(operator("direnv exec . idr process get docs-server -o json"))
            assert len(states) == 1, states
            return states[0]

        def server_responds():
            machine.wait_for_open_port(8080, addr="127.0.0.1", timeout=120)
            assert machine.succeed(
                "curl --fail --silent --show-error http://127.0.0.1:8080/"
            ) == "Project documentation\n"

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")
        operator("git add nix/local-docs/flake-module.nix")
        operator("direnv allow")

        daemon_started = False
        try:
            with subtest("a disabled process waits for an explicit start"):
                operator("direnv exec . idr -D")
                daemon_started = True
                state = server_state()
                assert not state["is_running"], state
                machine.fail("curl --fail --silent --max-time 2 http://127.0.0.1:8080/")

            with subtest("start and stop one configured process"):
                operator("direnv exec . idr process start docs-server")
                server_responds()
                operator("direnv exec . idr process stop docs-server")
                machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
                state = server_state()
                assert not state["is_running"], state

            with subtest("restart a running process"):
                operator("direnv exec . idr process start docs-server")
                server_responds()
                before = server_state()
                operator("direnv exec . idr process restart docs-server")
                server_responds()
                after = server_state()
                assert after["is_running"], after
                assert after["pid"] != before["pid"], (before, after)
        finally:
            if daemon_started:
                with subtest("stop Process Compose and its running process"):
                    operator("direnv exec . timeout --kill-after=10s 120s idr down")
                    machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
      '';
    });
  };
}

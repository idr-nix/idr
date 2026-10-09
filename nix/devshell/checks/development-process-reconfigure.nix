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
      imports = with top.self.modules.nixosTest; [base operator];

      name = "development-process-reconfigure";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

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

        def operator_command(command):
            return "su - operator -c " + shlex.quote("cd project && " + command)

        def operator(command):
            return machine.succeed(
                operator_command(command),
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
                operator("direnv allow")
                operator("direnv exec . idr -D")
                daemon_started = True
                server_responds(8080)

            with subtest("serve updates from the project's working directory"):
                operator("printf 'Updated documentation\\n' > docs/index.html")
                assert machine.succeed(
                    "curl --fail --silent --show-error http://127.0.0.1:8080/"
                ) == "Updated documentation\n"
                operator("printf 'Project documentation\\n' > docs/index.html")

            with subtest("follow two new requests with the same live logs command"):
                follower_started = False
                try:
                    follow = "echo $$ > .data/docs-follow.pid; exec idr process logs -f docs-server"
                    launch = (
                        "nohup timeout --kill-after=5s 120 bash -c " + shlex.quote(follow)
                        + " > .data/docs-follow.log 2>&1 </dev/null & echo $! > .data/docs-follow-timeout.pid"
                    )
                    operator("direnv exec . bash -c " + shlex.quote(launch))
                    follower_started = True
                    machine.wait_until_succeeds(operator_command("test -s .data/docs-follow.pid"), timeout=20)
                    follower_pid = int(operator("cat .data/docs-follow.pid").strip())
                    for request in ["log-follow-first", "log-follow-second"]:
                        machine.succeed(
                            "curl --fail --silent --show-error http://127.0.0.1:8080/?" + request
                        )
                        machine.wait_until_succeeds(operator_command(
                            f"kill -0 {follower_pid} && grep -F "
                            + shlex.quote("GET /?" + request + " HTTP/") + " .data/docs-follow.log"
                        ), timeout=20)
                finally:
                    if follower_started:
                        # Terminating timeout also stops the follower's process group.
                        machine.execute(operator_command("kill $(cat .data/docs-follow-timeout.pid)"))

            with subtest("reload edited process configuration automatically and restart IDR"):
                operator("sed -i 's/8080/8081/g' nix/local-docs/flake-module.nix")
                operator("direnv exec . idr down")
                daemon_started = False
                machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
                operator("direnv exec . idr -D")
                daemon_started = True
                server_responds(8081)
                machine.fail("curl --fail --silent --max-time 2 http://127.0.0.1:8080/")
        finally:
            if daemon_started:
                with subtest("stop the reconfigured project"):
                    operator("direnv exec . idr down")
                    machine.wait_for_closed_port(8081, addr="127.0.0.1", timeout=60)
                    machine.wait_for_closed_port(8080, addr="127.0.0.1", timeout=60)
      '';
    });
  };
}

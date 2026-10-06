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
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "development-process-controls";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default config.node.pkgs.python3];

      defaults = {pkgs, ...}: {
        environment.systemPackages = [pkgs.curl pkgs.jq];
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
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")
        operator("git add nix/local-docs/flake-module.nix")

        # No checkout changes occur during these controls. Run the real commands
        # in one development shell, including polling and failure cleanup.
        with subtest("control the disabled documentation process"):
            commands = r"""
                set -o pipefail
                wait_for_port() {
                    local wanted="$1" deadline=$((SECONDS + "$2"))
                    while true; do
                        if { : > /dev/tcp/127.0.0.1/8080; } 2>/dev/null; then
                            test "$wanted" = open && return 0
                        else
                            test "$wanted" = closed && return 0
                        fi
                        test "$SECONDS" -lt "$deadline" || return 1
                        sleep 1
                    done
                }
                server_state() {
                    local states
                    states=$(idr process get docs-server -o json) || return
                    printf '%s\n' "$states" | jq -e 'length == 1' >/dev/null || return
                    printf '%s\n' "$states" | jq '.[0]'
                }
                server_responds() {
                    wait_for_port open 120
                    curl --fail --silent --show-error http://127.0.0.1:8080/ > /tmp/docs-response
                    cmp /tmp/docs-response <(printf 'Project documentation\n')
                }
                cleanup() {
                    local status=$?
                    trap - EXIT
                    timeout --kill-after=10s 120s idr down || status=1
                    wait_for_port closed 60 || status=1
                    exit "$status"
                }

                echo 'a disabled process waits for an explicit start'
                idr -D
                trap cleanup EXIT
                server_state | jq -e '.is_running | not' >/dev/null
                if curl --fail --silent --max-time 2 http://127.0.0.1:8080/; then
                    exit 1
                fi

                echo 'start and stop one configured process'
                idr process start docs-server
                server_responds
                idr process stop docs-server
                wait_for_port closed 60
                server_state | jq -e '.is_running | not' >/dev/null

                echo 'restart a running process'
                idr process start docs-server
                server_responds
                before=$(server_state)
                idr process restart docs-server
                server_responds
                after=$(server_state)
                printf '%s\n' "$after" | jq -e '.is_running' >/dev/null
                test "$(printf '%s\n' "$after" | jq '.pid')" != "$(printf '%s\n' "$before" | jq '.pid')"
                echo 'stop Process Compose and its running process'
            """
            operator("nix develop -c bash -ec " + shlex.quote(commands))
      '';
    });
  };
}

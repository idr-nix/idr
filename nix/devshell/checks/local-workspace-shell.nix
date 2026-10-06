top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    mkCheck = scenario: testScript:
      pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (pkgs.stdenv.hostPlatform) isLinux;
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        machineId = top.self.nixosConfigurations."example-${system}".config.idr.preset.base.id;
      in {
        imports = with top.self.modules.nixosTest; [nix nix-store operator];

        # Darwin's build directory becomes part of the VM's Unix socket paths.
        # Keep this internal name short enough for its 104-byte socket limit.
        name = "workspace-${scenario}";
        globalTimeout = 20 * 60;

        idr.test.storePaths = [top.self.packages.${system}.default];

        defaults = {pkgs, ...}: {
          systemd.services.idr-project-fixture = {
            description = "Restore the project archive as a committed main checkout";
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
              git -C project init -q -b main
              git -C project add -A
              git -C project commit -qm 'Initial project'
            '';
          };
        };

        # The shell's SSH wrapper explicitly includes this configuration.
        containerDefaults = {
          environment.etc."ssh/ssh_config".mode = "0644";
          programs.ssh.systemd-ssh-proxy.enable = false;
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

        testScript = shellScript machineId + testScript;
      });
    shellScript = machineId: ''
      import ipaddress
      import pathlib
      import shlex

      def operator(directory, command):
          # Each login starts outside earlier development shells and their environment.
          return machine.succeed(
              "su - operator -c " + shlex.quote("cd " + directory + " && " + command),
              timeout=900,
          )

      def shell(directory, environment=""):
          command = (
              'printf "%s\\n" "$PRJ_ROOT" "$PRJ_DATA_DIR" "$PC_SOCKET_PATH" > /tmp/workspace-environment; '
              "ssh -G vm-test-machine > /tmp/workspace-ssh-config"
          )
          operator(directory, environment + "nix develop -c bash -ec " + shlex.quote(command))
          root, data, socket = machine.succeed("cat /tmp/workspace-environment").splitlines()
          settings = dict(line.split(" ", 1) for line in machine.succeed("cat /tmp/workspace-ssh-config").splitlines())
          return {
              "root": root,
              "data": data,
              "socket": socket,
              "address": ipaddress.IPv6Address(settings["hostname"]),
          }

      def assert_paths(state, directory, data=None):
          assert state["root"] == "/home/operator/" + directory, state
          assert state["data"] == (data or state["root"] + "/.data"), state
          assert pathlib.PurePosixPath(state["socket"]).parent == pathlib.PurePosixPath(state["data"]), state

      start_all()
      machine.wait_for_unit("idr-project-fixture.service")
      prefix = ipaddress.IPv6Network("fd3e:aacc:e60e::/48")
      machine_id = int("${machineId}", 16)

    '';
  in {
    checks = {
      local-workspace-shell-worktree = mkCheck "worktree" ''
        with subtest("the main checkout uses workspace zero and its own data directory"):
            main = shell("project")
            assert_paths(main, "project")
            assert main["address"] == ipaddress.IPv6Address(int(prefix.network_address) | machine_id), main

        with subtest("create and enter the documented linked worktree from outside the shell"):
            operator("project", "git worktree add -b local-feature ../project-local")
            linked = shell("project-local")
            assert_paths(linked, "project-local")
            assert linked["address"] in prefix, linked
            assert int(linked["address"]) & ((1 << 48) - 1) == machine_id, linked
            assert linked["address"] != main["address"], (main, linked)
            assert linked["data"] != main["data"], (main, linked)
            assert linked["socket"] != main["socket"], (main, linked)
            assert shell("project-local") == linked

      '';
      local-workspace-shell-workspace-override = mkCheck "workspace-override" ''
        operator("project", "git worktree add -b local-feature ../project-local")
        linked = shell("project-local")
        assert_paths(linked, "project-local")

        with subtest("an explicit workspace changes the address but keeps the checkout's data and socket"):
            explicit = shell("project-local", "env IDR_WORKSPACE_ID=42b08923 ")
            expected = ipaddress.IPv6Address(int(prefix.network_address) | (0x42b08923 << 48) | machine_id)
            assert explicit["address"] == expected, explicit
            assert explicit["address"] != linked["address"], (linked, explicit)
            assert {key: value for key, value in explicit.items() if key != "address"} == {
                key: value for key, value in linked.items() if key != "address"
            }, (linked, explicit)

      '';
      local-workspace-shell-data-override = mkCheck "data-override" ''
        main = shell("project")
        assert_paths(main, "project")

        with subtest("an explicit project data directory relocates the Process Compose socket"):
            overridden = shell("project", "env PRJ_DATA_DIR=/home/operator/project-data ")
            assert_paths(overridden, "project", "/home/operator/project-data")
            assert overridden["root"] == main["root"], (main, overridden)
            assert overridden["address"] == main["address"], overridden
            assert overridden["data"] != main["data"], (main, overridden)
            assert overridden["socket"] != main["socket"], (main, overridden)
      '';
    };
  };
}

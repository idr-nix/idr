top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.mk-module = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "mk-module";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive for a reusable module";
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
        import json
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        def instance_files():
            selection = (
                'host: with host.pkgs.lib; mapAttrs (_: file: file.text) '
                '(filterAttrs (name: _: hasPrefix "some-module-" name) host.config.environment.etc)'
            )
            return json.loads(operator(
                "nix eval --json .#nixosConfigurations.test-machine "
                "--apply " + shlex.quote(selection)
            ))

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("create a reusable module following the documentation"):
            operator("nix develop -c idr-mk-module some-module")
            operator(
                "git ls-files --error-unmatch "
                "nix/some-module/flake-module.nix nix/some-module/nixos-module.nix"
            )

        with subtest("automatically import the module and configure only enabled instances"):
            module_config = (
                r'/config = lib.mkIf (cfgs != {}) {/a\    '
                'environment.etc = lib.concatMapAttrs (name: cfg: { '
                '"some-module-''${name}".text = name; }) cfgs;'
            )
            operator(
                "sed -i " + shlex.quote(module_config) + " nix/some-module/nixos-module.nix"
            )
            files = instance_files()
            assert files == {}, files

            machine_config = (
                r'/config = lib.mkMerge \[/a\    '
                '{ idr.some-module = { first = {}; second = {}; paused.enable = false; }; }'
            )
            operator(
                "sed -i " + shlex.quote(machine_config)
                + " nix/machine/test-machine/configuration.nix"
            )
            files = instance_files()
            assert files == {"some-module-first": "first", "some-module-second": "second"}, files
      '';
    });
  };
}

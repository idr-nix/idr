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
      imports = with top.self.modules.nixosTest; [base operator];

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

        def module_state():
            selection = (
                'host: with host.pkgs.lib; { '
                'project = mapAttrs (_: cfg: cfg.enable) host.config.idr.project.project.some-module; '
                'empty = mapAttrs (_: cfg: cfg.enable) host.config.idr.project.project."123-module"; '
                'custom = mapAttrs (_: cfg: cfg.enable) host.config.custom."123"."if"; '
                'files = mapAttrs (_: file: file.text) '
                '(filterAttrs (name: _: hasPrefix "some-module-" name || hasPrefix "123-module-" name '
                '|| hasPrefix "if-" name) '
                'host.config.environment.etc); }'
            )
            return json.loads(operator(
                "direnv exec . nix eval --json .#nixosConfigurations.test-machine "
                "--apply " + shlex.quote(selection)
            ))

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")
        operator("direnv allow")

        with subtest("create a reusable module following the documentation"):
            operator("direnv exec . env -u IDR_PROJECT_NAMESPACE idr-mk-module some-module")
            operator(
                "git ls-files --error-unmatch "
                "nix/some-module/flake-module.nix nix/some-module/nixos-module.nix"
            )

        with subtest("derive the project namespace for an empty override and a digit-prefixed module name"):
            operator("direnv exec . env IDR_PROJECT_NAMESPACE= idr-mk-module 123-module")
            operator(
                "git ls-files --error-unmatch nix/123-module/flake-module.nix nix/123-module/nixos-module.nix"
            )

        with subtest("use an explicit namespace and a keyword module name"):
            operator("direnv exec . env IDR_PROJECT_NAMESPACE=custom.123 idr-mk-module if")
            operator(
                "git ls-files --error-unmatch nix/if/flake-module.nix nix/if/nixos-module.nix"
            )

        with subtest("automatically import the module and configure only enabled instances"):
            for name in ("some-module", "123-module", "if"):
                module_config = (
                    r'/config = lib.mkIf (cfgs != {}) {/a\    '
                    'environment.etc = lib.concatMapAttrs (name: cfg: { '
                    '"' + name + '-''${name}".text = name; }) cfgs;'
                )
                operator(
                    "sed -i " + shlex.quote(module_config) + " nix/" + name + "/nixos-module.nix"
                )
            state = module_state()
            assert state == {"project": {}, "empty": {}, "custom": {}, "files": {}}, state

            machine_config = (
                r'/config = lib.mkMerge \[/a\    '
                '{ idr.project.project.some-module = { first = {}; second = {}; paused.enable = false; }; '
                'idr.project.project."123-module" = { active = {}; paused.enable = false; }; '
                'custom."123"."if" = { active = {}; paused.enable = false; }; }'
            )
            operator(
                "sed -i " + shlex.quote(machine_config)
                + " nix/machine/test-machine/configuration.nix"
            )
            state = module_state()
            assert state == {
                "project": {"first": True, "second": True, "paused": False},
                "empty": {"active": True, "paused": False},
                "custom": {"active": True, "paused": False},
                "files": {
                    "some-module-first": "first",
                    "some-module-second": "second",
                    "123-module-active": "active",
                    "if-active": "active",
                },
            }, state
      '';
    });
  };
}

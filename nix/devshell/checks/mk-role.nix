top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.mk-role = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "mk-role";
      globalTimeout = 15 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the mk-project archive";
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
                timeout=600,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")
        operator("direnv allow")

        with subtest("create the documented role and track its generated files"):
            operator("direnv exec . idr-mk-role some-role </dev/null")
            operator(
                "git ls-files --error-unmatch nix/role/flake-module.nix "
                "nix/role/some-role/meta.json nix/role/some-role/flake-module.nix "
                "nix/role/some-role/nixos-module.nix"
            )
            metadata = json.loads(operator("cat nix/role/some-role/meta.json"))
            role_name = "some-role-" + metadata["id"]

        with subtest("accept role names beginning with a digit"):
            operator("direnv exec . idr-mk-role 123-role </dev/null")
            operator(
                "git ls-files --error-unmatch nix/role/123-role/meta.json "
                "nix/role/123-role/flake-module.nix nix/role/123-role/nixos-module.nix"
            )
            metadata = json.loads(operator("cat nix/role/123-role/meta.json"))
            numeric_role_name = "123-role-" + metadata["id"]

        with subtest("settings in the generated conditional block stay disabled by default"):
            for name in ("some-role", "123-role"):
                role_config = (
                    r'/config = lib.mkIf cfg.enable {/a\    '
                    'environment.etc."role-message-' + name + '".text = "' + name + ' enabled";'
                )
                operator(
                    "sed -i " + shlex.quote(role_config) + " nix/role/" + name + "/nixos-module.nix"
                )
            expression = (
                'host: with host.pkgs.lib; { enabled = { '
                'some-role = host.config.idr.roles."' + role_name + '".enable; '
                '"123-role" = host.config.idr.roles."' + numeric_role_name + '".enable; }; '
                'messages = mapAttrs (_: file: file.text) '
                '(filterAttrs (name: _: hasPrefix "role-message-" name) host.config.environment.etc); }'
            )
            evaluate = (
                "direnv exec . nix eval --json .#nixosConfigurations.test-machine --apply "
                + shlex.quote(expression)
            )
            state = json.loads(operator(evaluate))
            assert state == {"enabled": {"some-role": False, "123-role": False}, "messages": {}}, state

        with subtest("enable the role using its generated name and ID"):
            role_enables = (
                r'/networking.hostName =/a\      '
                'idr.roles."' + role_name + '".enable = true; '
                'idr.roles."' + numeric_role_name + '".enable = true;'
            )
            operator(
                "sed -i " + shlex.quote(role_enables) + " nix/machine/test-machine/configuration.nix"
            )
            state = json.loads(operator(evaluate))
            assert state == {
                "enabled": {"some-role": True, "123-role": True},
                "messages": {
                    "role-message-some-role": "some-role enabled",
                    "role-message-123-role": "123-role enabled",
                },
            }, state
      '';
    });
  };
}

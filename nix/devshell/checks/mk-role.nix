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
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

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

        with subtest("create the documented role and track its generated files"):
            operator("nix develop -c idr-mk-role some-role </dev/null")
            operator(
                "git ls-files --error-unmatch nix/role/flake-module.nix "
                "nix/role/some-role/meta.json nix/role/some-role/flake-module.nix "
                "nix/role/some-role/nixos-module.nix"
            )
            metadata = json.loads(operator("cat nix/role/some-role/meta.json"))
            role_name = "some-role-" + metadata["id"]

        with subtest("settings in the generated conditional block stay disabled by default"):
            operator(
                "sed -i 's|lib.mkIf cfg.enable {}|lib.mkIf cfg.enable { "
                "environment.etc.role-message.text = \"some-role enabled\"; }|' "
                "nix/role/some-role/nixos-module.nix"
            )
            expression = (
                'config: { enabled = config.idr.roles."' + role_name + '".enable; '
                'message = (config.environment.etc.role-message or { text = null; }).text; }'
            )
            evaluate = (
                "nix eval --json .#nixosConfigurations.test-machine.config --apply "
                + shlex.quote(expression)
            )
            state = json.loads(operator(evaluate))
            assert state == {"enabled": False, "message": None}, state

        with subtest("enable the role using its generated name and ID"):
            operator(
                "sed -i '/networking.hostName =/a\\      idr.roles.\"" + role_name
                + "\".enable = true;' nix/machine/test-machine/configuration.nix"
            )
            state = json.loads(operator(evaluate))
            assert state == {"enabled": True, "message": "some-role enabled"}, state
      '';
    });
  };
}

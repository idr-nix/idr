top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    documentedModule = pkgs.writeText "documented-module.nix" ''
      _: {
        flake.modules.nixos.documentation-example = {lib, ...}: {
          options.services.documented.message = lib.mkOption {
            type = lib.types.str;
            default = "Welcome";
            description = "Initial greeting for the documented service.";
          };
        };
      }
    '';
  in {
    checks.documentation-regenerate = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "documentation-regenerate";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the mk-project archive";
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
            mkdir -p project/nix/documentation-example
            cp --no-preserve=mode ${documentedModule} project/nix/documentation-example/flake-module.nix
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
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")
        operator("direnv allow")

        with subtest("generate the reference for an exported module"):
            operator("direnv exec . bash -euc 'rm -rf docs/generated; idr-generate-docs'")
            reference = operator("cat docs/generated/nixos-options.md").replace(r"\.", ".")
            assert "services.documented.message" in reference, "expected option or description is missing"
            assert "Initial greeting for the documented service." in reference, "expected option or description is missing"

        with subtest("edit the option description and regenerate the reference"):
            operator(
                "sed -i 's/Initial greeting for the documented service./Greeting displayed when the service starts./' "
                "nix/documentation-example/flake-module.nix"
            )
            # The Nix edit reloads direnv and refreshes documentation too. Remove its output to exercise
            # the documented manual command independently of the startup hook.
            operator("direnv exec . bash -euc 'rm -rf docs/generated; idr-generate-docs'")
            reference = operator("cat docs/generated/nixos-options.md").replace(r"\.", ".")
            assert "services.documented.message" in reference, "expected option or description is missing"
            assert "Greeting displayed when the service starts." in reference, "expected option or description is missing"
            assert "Initial greeting for the documented service." not in reference, "the old description remains in the reference"

      '';
    });
  };
}

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.documentation-disabled = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports =
        (with top.self.modules.nixosTest; [base operator])
        ++ [
          (lib.modules.importApply ./fixtures/documentation-project.nix {
            inherit project;
            inherit (pkgs.stdenv.hostPlatform) isLinux;
            extraSetup = ''
              mkdir -p nix/documentation
              cp --no-preserve=mode ${./fixtures/documentation-disabled/flake-module.nix} nix/documentation/flake-module.nix
            '';
          })
        ];

      name = "documentation-disabled";
      idr.test.storePaths = [top.self.packages.${system}.default];

      testScript = ''
        import shlex

        def operator(command, *, succeeds=True):
            run = machine.succeed if succeeds else machine.fail
            return run(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")
        operator("direnv allow")

        with subtest("opt out of documentation helpers while using the development shell"):
            operator("rm -rf docs/generated")
            menu = operator("direnv exec . menu")
            operator("direnv exec . bash -c 'command -v idr-generate-docs'", succeeds=False)
            operator("test ! -d docs/generated")
            assert "idr-mk-machine" in menu, "the normal project commands are unavailable"

        with subtest("the documentation build command is no longer exported"):
            output = operator("nix build .#idr-mk-docs 2>&1", succeeds=False)
            assert "does not provide attribute" in output and "idr-mk-docs" in output, output
      '';
    });
  };
}

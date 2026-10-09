top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.documentation-special-args = pkgs.testers.runNixOSTest ({config, ...}: let
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
              cp --no-preserve=mode ${./fixtures/documentation-special-args/flake-module.nix} nix/documentation/flake-module.nix
            '';
          })
        ];

      name = "documentation-special-args";
      idr.test.storePaths = [top.self.packages.${system}.default];

      testScript = ''
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("build an option reference whose module needs an extra argument"):
            operator("nix build .#idr-mk-docs")
            reference = operator("cat result/html/docs/generated/nixos-options.html")
            assert "services.documentationExample.endpoint" in reference, "the custom module option is missing"
            assert "https://api.example.invalid" in reference, "the default from the module argument is missing"
            assert "Endpoint used by the documentation example service." in reference, "the option description is missing"
      '';
    });
  };
}

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.documentation-library = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports =
        (with top.self.modules.nixosTest; [nix nix-store operator])
        ++ [
          (lib.modules.importApply ./fixtures/documentation-project.nix {
            inherit project;
            inherit (pkgs.stdenv.hostPlatform) isLinux;
            extraSetup = ''
              mkdir -p nix/documentation
              cp --no-preserve=mode ${./fixtures/documentation-library/flake-module.nix} nix/documentation/flake-module.nix
              mkdir -p nix/lib
              cp --no-preserve=mode ${./fixtures/documentation-library/helpers.nix} nix/lib/helpers.nix
            '';
          })
        ];

      name = "documentation-library";
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

        with subtest("generate a library reference from function comments"):
            operator("nix develop -c idr-generate-docs")
            reference = operator("cat docs/generated/lib.md")
            assert "lib.greet" in reference, reference
            assert "Return a greeting for the named project operator." in reference, reference
            assert "The operator's display name." in reference, reference
            assert 'lib.greet "Robin"' in reference, reference

        with subtest("the generated library reference is available in the built book"):
            operator("nix build .#idr-mk-docs")
            reference = operator("cat result/html/docs/generated/lib.html")
            assert "lib.greet" in reference, "the prefixed function is missing from the book"
            assert "Return a greeting for the named project operator." in reference, "function documentation is missing from the book"
            contents = operator("cat result/html/toc.html")
            assert 'href="docs/generated/lib.html"' in contents, "the library reference is not linked"
      '';
    });
  };
}

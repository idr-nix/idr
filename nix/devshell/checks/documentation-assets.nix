top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.documentation-assets = pkgs.testers.runNixOSTest ({config, ...}: let
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
              cp --no-preserve=mode ${./fixtures/documentation-assets/flake-module.nix} nix/documentation/flake-module.nix
            '';
          })
        ];

      name = "documentation-assets";
      idr.test.storePaths = [top.self.packages.${system}.default];

      testScript = ''
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("set -e\ncd project\n" + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("include a directory and a single file as documentation assets"):
            operator(r"""
                mkdir -p docs/assets/icons
                printf '<svg xmlns="http://www.w3.org/2000/svg"><title>Project logo</title></svg>\n' > docs/assets/icons/logo.svg
                printf 'Example project license: redistribution permitted.\n' > LICENSE
                printf '# Project assets\n\nRestore the application database before starting services.\n\n![Project logo](assets/icons/logo.svg)\n\n[License](../LICENSE)\n' > docs/assets.md
                printf '\n- [Project assets](docs/assets.md)\n' >> SUMMARY.md
                git add docs LICENSE SUMMARY.md
                nix build .#idr-mk-docs
            """)

        with subtest("the build contains a readable introduction and the linked guide"):
            introduction = operator("cat result/html/index.html")
            assert "<html" in introduction.lower(), "introduction is not HTML"
            contents = operator("cat result/html/toc.html")
            assert 'href="docs/assets.html"' in contents, "guide is missing from the table of contents"
            guide = operator("cat result/html/docs/assets.html")
            assert "<html" in guide.lower(), "guide is not HTML"
            assert "Restore the application database before starting services." in guide, "guide text is missing"

        with subtest("the built guide links to the unchanged packaged assets"):
            operator("""
                cmp docs/assets/icons/logo.svg result/html/docs/assets/icons/logo.svg
                cmp LICENSE result/html/LICENSE
            """)
            assert 'src="assets/icons/logo.svg"' in guide, "the logo link is missing"
            assert 'href="../LICENSE"' in guide, "the license link is missing"
      '';
    });
  };
}

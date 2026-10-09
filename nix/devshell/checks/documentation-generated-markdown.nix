top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.documentation-generated-markdown = pkgs.testers.runNixOSTest ({config, ...}: let
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
              cp --no-preserve=mode ${./fixtures/documentation-generated-markdown/flake-module.nix} nix/documentation/flake-module.nix
            '';
          })
        ];

      name = "documentation-generated-markdown";
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

        with subtest("include package-generated Markdown during the book build"):
            operator("printf '\\n- [API](docs/api.md)\\n' >> SUMMARY.md")
            operator("git add SUMMARY.md")
            operator("test ! -e docs/api.md")
            operator("nix build .#idr-mk-docs")
            guide = operator("cat result/html/docs/api.html")
            assert "Send a GET request to /health" in guide, "generated API documentation is missing"
            contents = operator("cat result/html/toc.html")
            assert 'href="docs/api.html"' in contents, "generated API guide is not linked"
            operator("test ! -e docs/api.md")

        with subtest("rebuilding uses the updated generator output"):
            operator("sed -i 's|/health|/ready|' nix/documentation/flake-module.nix")
            operator("nix build .#idr-mk-docs")
            guide = operator("cat result/html/docs/api.html")
            assert "Send a GET request to /ready" in guide, "updated API documentation is missing"
            assert "Send a GET request to /health" not in guide, "the old generator output remains"
      '';
    });
  };
}

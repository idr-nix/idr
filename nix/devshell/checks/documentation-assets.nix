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
        (with top.self.modules.nixosTest; [nix nix-store operator])
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
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("include a directory and a single file as documentation assets"):
            operator("mkdir -p docs/assets/icons")
            operator("printf '<svg xmlns=\"http://www.w3.org/2000/svg\"><title>Project logo</title></svg>\\n' > docs/assets/icons/logo.svg")
            operator("printf 'Example project license: redistribution permitted.\\n' > LICENSE")
            operator("printf '# Project assets\\n\\n![Project logo](assets/icons/logo.svg)\\n\\n[License](../LICENSE)\\n' > docs/assets.md")
            operator("printf '\\n- [Project assets](docs/assets.md)\\n' >> SUMMARY.md")
            operator("git add docs LICENSE SUMMARY.md")
            operator("nix build .#idr-mk-docs")

        with subtest("the built guide links to the unchanged packaged assets"):
            operator("cmp docs/assets/icons/logo.svg result/html/docs/assets/icons/logo.svg")
            operator("cmp LICENSE result/html/LICENSE")
            guide = operator("cat result/html/docs/assets.html")
            assert 'src="assets/icons/logo.svg"' in guide, "the logo link is missing"
            assert 'href="../LICENSE"' in guide, "the license link is missing"
      '';
    });
  };
}

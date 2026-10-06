top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.documentation-search = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports =
        (with top.self.modules.nixosTest; [nix nix-store operator])
        ++ [
          (lib.modules.importApply ./fixtures/documentation-project.nix {
            inherit project;
            inherit (pkgs.stdenv.hostPlatform) isLinux;
            extraSetup = ''
              mkdir -p nix/documentation-example
              cp --no-preserve=mode ${./fixtures/documentation-search/flake-module.nix} nix/documentation-example/flake-module.nix
            '';
          })
        ];

      name = "documentation-search";
      idr.test.storePaths = [
        top.self.packages.${system}.default
        config.node.pkgs.fzf
        (lib.getMan config.node.pkgs.fzf)
      ];

      testScript = ''
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("find a project option and read its preview"):
            operator("nix develop -c bash -euo pipefail -c " + shlex.quote(
                "nix-search-tv print > .data/search-options; "
                "fzf --filter services.documentationExample.greeting < .data/search-options > .data/selected-option; "
                'nix-search-tv preview "$(cat .data/selected-option)" > .data/option-preview'
            ))
            selection = operator("cat .data/selected-option")
            assert "services.documentationExample.greeting" in selection, selection
            preview = operator("cat .data/option-preview")
            assert "Greeting shown by the documentation search example." in preview, preview
            assert "Hello from the project" in preview, preview

        with subtest("search also includes options from supported inputs"):
            operator("nix develop -c bash -euo pipefail -c " + shlex.quote(
                "fzf --filter services.openssh.enable < .data/search-options > .data/input-option; "
                'nix-search-tv preview "$(head -n 1 .data/input-option)" > .data/input-preview'
            ))
            preview = operator("cat .data/input-preview")
            assert "OpenSSH" in preview, preview
      '';
    });
  };
}

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
        (with top.self.modules.nixosTest; [base operator])
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
        operator("direnv allow")

        with subtest("find a project option and read its preview"):
            operator("direnv exec . bash -euc 'nix-search-tv print > .data/search-options'")
            operator("direnv exec . bash -euc 'fzf --filter services.documentationExample.greeting < .data/search-options > .data/selected-option'")
            selection = operator("cat .data/selected-option")
            assert "services.documentationExample.greeting" in selection, selection
            preview = operator("direnv exec . bash -euo pipefail -c " + shlex.quote(
                'nix-search-tv preview "$(cat .data/selected-option)"'
            ))
            assert "Greeting shown by the documentation search example." in preview, preview
            assert "Hello from the project" in preview, preview

        with subtest("search also includes options from supported inputs"):
            operator("direnv exec . bash -euc 'fzf --filter services.openssh.enable < .data/search-options > .data/input-option'")
            preview = operator("direnv exec . bash -euo pipefail -c " + shlex.quote(
                'nix-search-tv preview "$(head -n 1 .data/input-option)"'
            ))
            assert "OpenSSH" in preview, preview
      '';
    });
  };
}

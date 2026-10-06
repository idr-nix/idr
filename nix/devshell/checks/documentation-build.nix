top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.documentation-build = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "documentation-build";
      globalTimeout = 20 * 60;

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
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("add a guide to the book and build the documentation"):
            operator("mkdir -p docs")
            operator("printf '# Operations guide\\n\\nRestore the application database before starting services.\\n' > docs/operations.md")
            operator("printf '\\n- [Operations guide](docs/operations.md)\\n' >> SUMMARY.md")
            operator("git add docs/operations.md SUMMARY.md")
            operator("nix build .#idr-mk-docs")

        with subtest("the build contains a readable introduction and the linked guide"):
            introduction = operator("cat result/html/index.html")
            assert "<html" in introduction.lower(), "introduction is not HTML"
            contents = operator("cat result/html/toc.html")
            assert 'href="docs/operations.html"' in contents, "guide is missing from the table of contents"
            guide = operator("cat result/html/docs/operations.html")
            assert "<html" in guide.lower(), "guide is not HTML"
            assert "Restore the application database before starting services." in guide, "guide text is missing"

      '';
    });
  };
}

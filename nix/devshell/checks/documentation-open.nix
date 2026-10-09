top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.documentation-open = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "documentation-open";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        environment.systemPackages = [
          (pkgs.writeShellScriptBin "record-browser" ''
            set -eu
            printf '%s\n' "$@" > "$HOME/browser-arguments"
            for argument in "$@"; do
              page="$argument"
            done
            cat "$page" > "$HOME/opened-documentation.html"
          '')
        ];
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

        with subtest("open project documentation with the selected browser and its arguments"):
            operator("printf '\\nRead the operator handbook before deploying.\\n' >> README.md")
            operator("BROWSER=record-browser BROWSER_ARGS='--new-window --private-window' nix run .#idr-open-docs")

            arguments = operator("cat ~/browser-arguments").splitlines()
            assert len(arguments) == 3, arguments
            assert arguments[:2] == ["--new-window", "--private-window"], arguments
            assert arguments[2].startswith("/nix/store/"), arguments
            assert arguments[2].endswith("/html/index.html"), arguments
            opened_documentation = operator("cat ~/opened-documentation.html")
            assert "<html" in opened_documentation.lower(), "browser did not open HTML"
            assert "Read the operator handbook before deploying." in opened_documentation, "browser did not open the project documentation"

      '';
    });
  };
}

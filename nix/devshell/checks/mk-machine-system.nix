top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.mk-machine-system = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "mk-machine-system";
      globalTimeout = 15 * 60;

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
            memorySize = 4096;
            cores = 2;
          };
          networking.useDHCP = false;
        };
      };

      testScript = ''
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=600,
            )

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("create the documented non-default architecture with -s"):
            operator("nix develop -c idr-mk-machine -s aarch64-linux arm-machine </dev/null")
            operator(
                "git ls-files --error-unmatch nix/machine/arm-machine/flake-module.nix "
                "nix/machine/arm-machine/configuration.nix nix/machine/arm-machine/hardware-specific.nix "
                "nix/machine/arm-machine/secrets.enc.json nix/machine/arm-machine/disk-key.enc.json"
            )

        with subtest("the generated NixOS configuration targets aarch64-linux"):
            system = operator(
                "nix eval --raw .#nixosConfigurations.arm-machine.pkgs.stdenv.hostPlatform.system"
            ).strip()
            assert system == "aarch64-linux", system
      '';
    });
  };
}

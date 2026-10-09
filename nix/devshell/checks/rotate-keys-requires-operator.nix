top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.rotate-keys-requires-operator = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "rotate-keys-requires-operator";
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
            memorySize = 8192;
            cores = 8;
          };
          networking.useDHCP = false;
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        import shlex

        def operator(command, succeeds=True):
            run = machine.succeed if succeeds else machine.fail
            return run("su - operator -c " + shlex.quote("cd project && " + command), timeout=900)

        operator("direnv allow")

        with subtest("refuse rotation that would leave only the replaced bootstrap identity"):
            # Take the refusal snapshot after the same startup hooks as the rotation command.
            operator("direnv exec . bash -euc 'sha256sum nix/machine/test-machine/*.enc.json > /tmp/before.sha256'")
            failure = operator("direnv exec . idr-rotate-keys --force test-machine 2>&1", succeeds=False)
            assert "remaining operator recipient must be able to decrypt" in failure, failure
            operator("sha256sum --check /tmp/before.sha256")
            operator("test -s .data/machine-host-key/test-machine")
            operator("test -s .data/machine-host-key/test-machine.pub")
            operator("direnv exec . sops decrypt --output /dev/null nix/machine/test-machine/secrets.enc.json")
            operator("direnv exec . sops decrypt --output /dev/null nix/machine/test-machine/disk-key.enc.json")
      '';
    });
  };
}

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
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

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

        with subtest("refuse rotation that would leave only the replaced bootstrap identity"):
            machine.succeed(
                "su - operator -c 'cd project && nix develop -c bash -e' <<'COMMANDS'\n"
                "sha256sum nix/machine/test-machine/*.enc.json > /tmp/before.sha256\n"
                "if idr-rotate-keys --force test-machine > /tmp/rotation.log 2>&1; then\n"
                "  echo 'Rotation unexpectedly succeeded without an operator recipient' >&2\n"
                "  exit 1\n"
                "fi\n"
                "grep -q 'remaining operator recipient must be able to decrypt' /tmp/rotation.log\n"
                "sha256sum --check /tmp/before.sha256\n"
                "test -s .data/machine-host-key/test-machine\n"
                "test -s .data/machine-host-key/test-machine.pub\n"
                "sops decrypt --output /dev/null nix/machine/test-machine/secrets.enc.json\n"
                "sops decrypt --output /dev/null nix/machine/test-machine/disk-key.enc.json\n"
                "COMMANDS",
                timeout=900,
            )
      '';
    });
  };
}

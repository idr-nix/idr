top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.mk-machine = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "mk-machine";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

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
        machine.wait_for_unit("multi-user.target")

        with subtest("create a machine in the project archive"):
            machine.copy_from_host("${project}/project.tar", "/tmp/project.tar")
            machine.succeed(
                "tar -C /home/operator --same-owner -xf /tmp/project.tar"
            )
            machine.succeed("su - operator -c 'cd project && git init -q && git add -A'")
            machine.succeed(
                "su - operator -c 'cd project && "
                "nix --offline develop -c idr-mk-machine -s ${system} another-machine </dev/null'",
                timeout=900,
            )
      '';
    });
  };
}

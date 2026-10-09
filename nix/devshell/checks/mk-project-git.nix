top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.mk-project-git = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      devshell = top.self.packages.${config.node.pkgs.stdenv.hostPlatform.system}.default;
    in {
      imports = with top.self.modules.nixosTest; [base operator ssh-git];

      name = "mk-project-git";
      globalTimeout = 15 * 60;

      idr.test.storePaths = [devshell];
      idr.test.sshGit.repositories = [
        {
          source = top.self;
          url = "git+ssh://git@github.com/idr-nix/idr";
        }
      ];

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
        machine.wait_for_unit("sshd.service")

        with subtest("follow the README's new-project command as a normal user"):
            machine.succeed(
                "su - operator -c 'nix run \"git+ssh://git@github.com/idr-nix/idr\" -- idr-mk-project path/to/project'",
                timeout=600,
            )
            machine.succeed(
                "su - operator -c 'cd path/to/project && test -f .env && "
                "git ls-files --error-unmatch flake.nix flake.lock .envrc .gitignore'"
            )
      '';
    });
  };
}

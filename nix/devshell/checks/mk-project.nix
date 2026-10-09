top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.mk-project = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
      devshell = top.self.packages.${system}.default;
      example = "example-${system}";
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "mk-project";
      globalTimeout = 15 * 60;

      idr.test.storePaths = [devshell];

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

        start_all()
        machine.wait_for_unit("multi-user.target")

        with subtest("create a project offline as a normal user"):
            machine.succeed(
                "su - operator -c '${devshell}/bin/idr-mk-project project'",
                timeout=600,
            )
            machine.succeed(
                "su - operator -c 'cd project && test -f .env && "
                "git ls-files --error-unmatch flake.nix flake.lock .envrc .gitignore'"
            )

        with subtest("export the project name before entering its devshell"):
            envrc_check = (
                "cd project && "
                "watch_file() { :; }; watch_dir() { :; }; "
                'use() { test "$1" = flake && test "$(printenv IDR_PROJECT_NAME)" = project; }; '
                "unset IDR_PROJECT_NAME; source .envrc"
            )
            machine.succeed("su - operator -c " + shlex.quote(envrc_check))

        with subtest("add the example machine for this system as test-machine"):
            machine.succeed(
                "su - operator -c 'cd project && "
                "mkdir -p nix/machine && "
                "cp --no-preserve=mode ${top.self}/templates/machine/flake-module.nix nix/machine/flake-module.nix && "
                "cp -r --no-preserve=mode ${top.self}/nix/machine/${example} nix/machine/test-machine && "
                "sed -i s/${example}/test-machine/g nix/machine/test-machine/flake-module.nix nix/machine/test-machine/configuration.nix && "
                "chmod 0600 nix/machine/flake-module.nix nix/machine/test-machine/* && "
                "git add nix/machine && "
                "install -D -m 0600 ${top.self}/.data/machine-host-key/${example} .data/machine-host-key/test-machine && "
                "install -m 0644 ${top.self}/.data/machine-host-key/${example}.pub .data/machine-host-key/test-machine.pub'"
            )
            machine.succeed(
                "su - operator -c 'cd project && "
                "nix --offline eval --raw .#nixosConfigurations.test-machine.config.system.build.toplevel.drvPath'",
                timeout=600,
            )
        ${lib.optionalString (!isLinux) ''
          with subtest("allow emulated target devices to finish booting"):
              # Match the device allowance of NixOS test-instrumentation.
              machine.succeed(
                  "su - operator -c 'cd project && "
                  'sed -i "s/system[.]stateVersion =/systemd.settings.Manager.DefaultDeviceTimeoutSec = 300; system.stateVersion =/" '
                  "nix/machine/test-machine/configuration.nix && "
                  "git add nix/machine/test-machine/configuration.nix'"
              )
        ''}
        with subtest("export the project archive"):
            machine.succeed(
                "find /home/operator/project/.data -mindepth 1 -maxdepth 1 ! -name machine-host-key -exec rm -rf {} +"
            )
            machine.succeed(
                "tar -C /home/operator --exclude=project/.git --sort=name --mtime=@0 "
                "--owner=1000 --group=1000 --numeric-owner -c project > /tmp/project.tar"
            )
            machine.copy_from_machine("/tmp/project.tar")
      '';
    });
  };
}

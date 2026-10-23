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
      imports = with top.self.modules.nixosTest; [base operator];

      idr.test.direnv.offline = true;
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
        import json
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        machine_directory = "nix/machine/another-machine/"
        configuration = machine_directory + "configuration.nix"
        generated_files = [
            "flake-module.nix", "configuration.nix", "config/disko.nix", "config/network.nix",
            "secrets.enc.json", "disk-key.enc.json",
        ]

        start_all()
        machine.wait_for_unit("multi-user.target")

        with subtest("create a machine in the project archive"):
            machine.copy_from_host("${project}/project.tar", "/tmp/project.tar")
            machine.succeed(
                "tar -C /home/operator --same-owner -xf /tmp/project.tar"
            )
            operator("git init -q && git add -A && direnv allow")
            operator("direnv exec . idr-mk-machine -s ${system} another-machine </dev/null")

        with subtest("stage generated modules with private files and a searchable config directory"):
            operator("git ls-files --error-unmatch " + " ".join(
                machine_directory + file for file in generated_files
            ))
            modes = operator("stat -c %a " + " ".join(
                machine_directory + file for file in generated_files
            )).splitlines()
            assert modes == ["600"] * len(generated_files), modes
            operator("test -x " + machine_directory + "config && "
                "test ! -e " + machine_directory + "hardware-specific.nix")

        with subtest("load added config modules with project and NixOS arguments"):
            original_configuration = operator("cat " + configuration)
            module = (
                'top: {config, lib, ...}: { environment.etc."machine-config-import".text = '
                'lib.concatStringsSep ":" [config.networking.hostName '
                '(if top.inputs ? idr then "idr" else "missing")]; }'
            )
            operator("printf '%s\\n' " + shlex.quote(module)
                + " > " + machine_directory + "config/application.nix")
            operator("mkdir " + machine_directory + "config/ignored.nix && "
                "printf '%s\\n' " + shlex.quote('throw "non-module file was imported"')
                + " > " + machine_directory + "config/notes.txt && "
                "printf '%s\\n' " + shlex.quote('throw "nested directory was imported"')
                + " > " + machine_directory + "config/ignored.nix/default.nix && "
                "git add " + machine_directory + "config")
            state = json.loads(operator(
                "nix --offline eval --json .#nixosConfigurations --apply " + shlex.quote(
                    'machines: { value = machines.another-machine.config.environment.etc.machine-config-import.text; '
                    'isolated = !(machines.test-machine.config.environment.etc ? machine-config-import); }'
                )
            ))
            assert state == {"value": "another-machine:idr", "isolated": True}, state
            assert operator("cat " + configuration) == original_configuration
      '';
    });
  };
}

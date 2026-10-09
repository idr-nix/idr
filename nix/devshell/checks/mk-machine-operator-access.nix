top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.mk-machine-operator-access = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
      machineId = top.self.nixosConfigurations."example-${system}".config.idr.preset.base.id;
    in {
      imports =
        (with top.self.modules.nixosTest; [base operator ssh-git])
        ++ [
          (lib.modules.importApply ./fixtures/operator-project.nix {
            inherit project machineId;
            ageKeyFile = "wrong.age";
          })
        ];

      name = "mk-machine-operator-access";
      globalTimeout = 20 * 60;

      idr.test.direnv.extraArgs = ["--no-update-lock-file"];
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

        def operator(command, timeout=900):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=timeout,
            )

        start_all()
        machine.wait_for_unit("idr-operator-fixture.service")
        machine.wait_for_unit("sshd.service")

        with subtest("update the operator's team membership"):
            operator(
                "test -s .data/machine-host-key/test-machine && "
                "test -s .data/machine-host-key/test-machine.pub && "
                "nix flake update team",
                timeout=600,
            )
            operator("direnv allow")

        with subtest("reencrypt secrets but retain bootstrap keys when the operator key is wrong"):
            operator("direnv exec . true")
            operator("test -s .data/machine-host-key/test-machine")
            operator("test -s .data/machine-host-key/test-machine.pub")
            recipient = operator("cat ~/.config/idr/operator.age.pub").strip()
            for file in ["secrets.enc.json", "disk-key.enc.json"]:
                secrets = json.loads(operator("cat nix/machine/test-machine/" + file))
                assert any(key["recipient"] == recipient for key in secrets["sops"]["age"]), file

        with subtest("correct the operator key and decrypt both files after bootstrap cleanup"):
            operator("sed -i 's|wrong.age|operator.age|' .env")
            operator("direnv exec . true")
            operator("test ! -e .data/machine-host-key/test-machine")
            operator("test ! -e .data/machine-host-key/test-machine.pub")
            operator("direnv exec . sops decrypt --output /dev/null nix/machine/test-machine/secrets.enc.json")
            operator("direnv exec . sops decrypt --output /dev/null nix/machine/test-machine/disk-key.enc.json")
      '';
    });
  };
}

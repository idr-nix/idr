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
        (with top.self.modules.nixosTest; [nix nix-store operator ssh-git])
        ++ [
          (lib.modules.importApply ./fixtures/operator-project.nix {
            inherit project machineId;
            ageKeyFile = "wrong.age";
          })
        ];

      name = "mk-machine-operator-access";
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
        def operator_script(commands):
            return machine.succeed(
                "su - operator -c 'cd project && bash -e' <<'COMMANDS'\n"
                + commands + "COMMANDS",
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("idr-operator-fixture.service")
        machine.wait_for_unit("sshd.service")

        with subtest("update the operator's team membership"):
            machine.succeed(
                "su - operator -c 'cd project && "
                "test -s .data/machine-host-key/test-machine && "
                "test -s .data/machine-host-key/test-machine.pub && "
                "nix flake update team'",
                timeout=600,
            )

        with subtest("reencrypt secrets but retain bootstrap keys when the operator key is wrong"):
            operator_script(
                "nix develop --no-update-lock-file -c true\n"
                "test -s .data/machine-host-key/test-machine\n"
                "test -s .data/machine-host-key/test-machine.pub\n"
                "for file in nix/machine/test-machine/secrets.enc.json nix/machine/test-machine/disk-key.enc.json; do\n"
                "  jq -e --arg recipient \"$(cat ~/.config/idr/operator.age.pub)\" "
                "'any(.sops.age[]; .recipient == $recipient)' \"$file\" >/dev/null\n"
                "done\n"
            )

        with subtest("correct the operator key and decrypt both files after bootstrap cleanup"):
            operator_script(
                "sed -i 's|wrong.age|operator.age|' .env\n"
                "nix develop --no-update-lock-file -c bash -ec '\n"
                "  test ! -e .data/machine-host-key/test-machine\n"
                "  test ! -e .data/machine-host-key/test-machine.pub\n"
                "  sops decrypt --output /dev/null nix/machine/test-machine/secrets.enc.json\n"
                "  sops decrypt --output /dev/null nix/machine/test-machine/disk-key.enc.json\n"
                "'\n"
            )
      '';
    });
  };
}

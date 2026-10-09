top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.machine-hardware-report = pkgs.testers.runNixOSTest ({
      config,
      hostPkgs,
      ...
    }: let
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
      # Public test credentials from Nixpkgs, never an operator's real SSH key.
      sshKeys = import "${top.inputs.nixpkgs}/nixos/tests/ssh-keys.nix" config.node.pkgs;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "machine-hardware-report";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      nodes = {
        machine = {pkgs, ...}: {
          virtualisation = {
            memorySize = 8192;
            # Nix supplies the per-build CPU budget; zero means all host cores.
            qemu.options = lib.mkAfter [
              ''-smp "$(if [ "''${NIX_BUILD_CORES:-0}" -gt 0 ]; then printf '%s' "$NIX_BUILD_CORES"; else ${lib.getExe' hostPkgs.coreutils "nproc"}; fi)"''
            ];
          };
          networking.interfaces.eth1.ipv4.addresses = [
            {
              address = "192.0.2.20";
              prefixLength = 24;
            }
          ];
          programs.ssh.extraConfig = ''
            Host 192.0.2.10
              IdentityFile /home/operator/.ssh/id_ecdsa
              IdentitiesOnly yes
              StrictHostKeyChecking accept-new
              BatchMode yes
              ConnectTimeout 10
          '';
          systemd.tmpfiles.rules = [
            "d /home/operator/.ssh 0700 operator operator -"
            "C /home/operator/.ssh/id_ecdsa 0600 operator operator - ${sshKeys.snakeOilPrivateKey}"
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

        target = {
          nix.settings.eval-cores = lib.mkForce 2;
          virtualisation = {
            memorySize = 1536;
            cores = 2;
          };
          networking.interfaces.eth1.ipv4.addresses = [
            {
              address = "192.0.2.10";
              prefixLength = 24;
            }
          ];
          services.openssh.enable = true;
          users.users.root.openssh.authorizedKeys.keys = [sshKeys.snakeOilPublicKey];
          nix.registry.nixpkgs.flake = top.inputs.nixpkgs;
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

        def hardware_configuration(include_detection=True):
            expression = "config: { inherit (config.hardware.facter) enable report reportPath; "
            if include_detection:
                expression += (
                    "qemu = config.hardware.facter.detected.virtualisation.qemu.enable; "
                    "modules = config.boot.initrd.availableKernelModules; "
                )
            expression += "}"
            return json.loads(operator(
                "nix --offline eval --json .#nixosConfigurations.test-machine.config --apply "
                + shlex.quote(expression)
            ))

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")
        operator("direnv allow")
        target.wait_for_unit("sshd.service")

        with subtest("the existing machine has no hardware report yet"):
            before = hardware_configuration(include_detection=False)
            assert before["reportPath"] is None, before
            assert before["report"] == {}, before
            assert not before["enable"], before

        with subtest("generate the target hardware report through SSH and copy it into the project"):
            operator("direnv exec . bash -ec " + shlex.quote(
                "ssh root@192.0.2.10 'nix run nixpkgs#nixos-facter -- -o /tmp/facter.json'\n"
                "scp root@192.0.2.10:/tmp/facter.json nix/machine/test-machine/facter.json\n"
                "git add nix/machine/test-machine/facter.json\n"
                "git ls-files --error-unmatch nix/machine/test-machine/facter.json\n"
            ))
            report = json.loads(operator("cat nix/machine/test-machine/facter.json"))
            assert report["system"] == "${system}", report["system"]
            assert report["hardware"]["cpu"], "The target report has no CPU information"
            assert report["hardware"]["disk"], "The target report has no disk information"

        with subtest("the generated configuration loads the adjacent report and enables detected hardware"):
            after = hardware_configuration()
            assert after["reportPath"].endswith("/nix/machine/test-machine/facter.json"), after
            assert after["report"] == report, "The loaded report differs from the target's report"
            assert after["enable"], "Facter did not activate for the adjacent report"
            assert after["qemu"], "The target VM's virtualisation was not detected"
            assert "virtio_blk" in after["modules"], after["modules"]
      '';
    });
  };
}

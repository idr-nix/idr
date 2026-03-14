{
  pkgs,
  inputs,
  self,
  ...
}: let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  machineId = "1e6f6e96b47c";
  networkPrefix = "fd3e:aacc:e60e";
  workspace = "42b08923";
  address = "${networkPrefix}:42b0:8923:1e6f:6e96:b47c";
  keys = import (inputs.nixpkgs + /nixos/tests/ssh-keys.nix) pkgs;
  publicKey = keys.snakeOilEd25519PublicKey;

  # These are disposable test identities, never used outside the test VMs.
  fixtures =
    pkgs.runCommand "idr-guest-access-fixtures" {
      nativeBuildInputs = with pkgs; [age jq sops];
    } ''
      mkdir -p $out
      age-keygen -o $out/identity
      age-keygen -o $out/wrong-identity
      jq -n --rawfile key ${keys.snakeOilEd25519PrivateKey} '{ssh_private_key: $key}' |
        sops encrypt --age "$(age-keygen -y "$out/identity")" --input-type json --output-type json /dev/stdin > $out/secrets.enc.json
    '';

  guestServices = import ../../../preset/base/qemu/guest-services.nix {
    inherit lib machineId networkPrefix;
  };

  # Evaluate the production modules with the machine metadata required by SSH and readiness.
  qemu = (import ../flake-module.nix {}) {
    inherit lib;
    self.outPath = "/project";
    self.nixosConfigurations.guest = {
      inherit pkgs;
      config = {
        system.build.idrQemu = null;
        system.build.idr.meta = {
          sshHostPublicKey = publicKey;
          defaultSopsFile = "/project/nix/machine/guest/secrets.enc.json";
        };
        idr.preset.base.id = machineId;
        idr.qemu.networkPrefix = networkPrefix;
        services.openssh.enable = true;
        services.openssh.ports = [2222];
      };
    };
  };
  qemuSettings = qemu.perSystem {inherit pkgs system;};
  processSettings = (import inputs.process-compose-flake.lib {inherit pkgs;}).evalModules {
    modules = [{settings.processes = qemuSettings.process-compose.idr.settings.processes;}];
  };
  sshModule = (import ../../devshell/flake-module.nix {inherit inputs self;}) {
    inherit lib inputs self;
    config.idr.projectName = "guest-access";
  };
  sshSettings = sshModule.perSystem {
    inherit pkgs system;
    self' = {};
    config.devshells.default.idr.sshConfig = qemuSettings.devshells.default.idr.sshConfig;
  };
  clientProject = inputs.flake-parts.lib.mkFlake {inherit inputs;} {
    systems = [system];
    imports = [
      inputs.devshell.flakeModule
      (import ../../files/flake-module.nix {})
    ];
    perSystem = {
      idr.files = sshSettings.idr.files;
      devshells.default = {
        imports = [self.modules.devshell.idr];
        env = sshSettings.devshells.default.env;
        idr = {
          projectName = "guest-access";
          additionalPaths = lib.mkForce [];
        };
      };
    };
  };
  clientShell = clientProject.devShells.${system}.default;
in
  pkgs.testers.runNixOSTest {
    name = "idr-guest-access";
    globalTimeout = 10 * 60;

    defaults = {
      virtualisation.memorySize = 768;
      virtualisation.interfaces.eno1.vlan = 1;
      nix.settings.sandbox = true;
      boot.kernelModules = ["qemu_fw_cfg"];
      networking = {
        useNetworkd = true;
        useDHCP = false;
      };
      systemd.network.wait-online.enable = false;
      systemd.services = {
        idr-qemu-network = guestServices.network;
        idr-qemu-ssh = guestServices.ssh;
      };
      services.openssh = {
        enable = true;
        ports = [2222];
        hostKeys = [
          {
            type = "ed25519";
            path = "/etc/ssh/ssh_host_ed25519_key";
          }
        ];
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "prohibit-password";
        };
        authorizedKeysFiles = ["/run/idr-qemu-ssh/%u"];
      };
      virtualisation.qemu.options = [
        "-fw_cfg name=opt/io.systemd.credentials/idr.qemu-ssh-key,string='${publicKey}'"
      ];
    };

    nodes.guest = {
      system.switch.enable = true;
      virtualisation.qemu.options = [
        "-fw_cfg name=opt/io.systemd.credentials/idr.workspace-id,string=${workspace}"
        "-fw_cfg name=opt/io.systemd.credentials/idr.network-prefix-length,string=48"
      ];
    };

    # The client also exercises the production case: a key alone is insufficient.
    nodes.client = {
      systemd.network.networks."10-client" = {
        matchConfig.Name = "eno1";
        address = ["${networkPrefix}::1/48"];
      };
      environment.systemPackages = with pkgs; [
        coreutils
        openssh
      ];
      virtualisation.additionalPaths = [fixtures clientShell];
    };

    testScript =
      ''
        address = "${address}"
        public_key = "${publicKey}"
        fixtures = "${fixtures}"
        client_shell = "${clientShell}/entrypoint"
        system = "${system}"
        readiness_command = ${builtins.toJSON processSettings.config.settings.processes.vm-guest.readiness_probe.exec.command}
      ''
      + builtins.readFile ./guest-access/test.py;
  }

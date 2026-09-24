{
  pkgs,
  inputs,
  self,
  ...
}: let
  inherit (pkgs) lib;
  scripts = ../../../scripts;
  commands = import ../../../devshell/checks/commands.nix {inherit pkgs inputs self;};
  keys = import (inputs.nixpkgs + "/nixos/tests/ssh-keys.nix") pkgs;
  machineName = "lifecycle";
  machineId = "112233445566";
  networkPrefix = "fd3e:aacc:e60e";
  sshPort = 2222;
  nixpkgsLock = (lib.importJSON ../../../../flake.lock).nodes.nixpkgs;

  # A real EFI bootloader is enough to test disk precedence without building a
  # second installed NixOS closure. The wiped disk then boots the actual ISO.
  bootDisk =
    pkgs.runCommand "idr-qemu-test-disk" {
      nativeBuildInputs = with pkgs; [dosfstools gptfdisk grub2_efi mtools qemu];
    } ''
      mkdir -p $out
      cat > grub.cfg <<'EOF'
      serial --unit=0 --speed=115200
      terminal_output serial
      echo IDR_TEST_DISK_BOOTED
      sleep 3600
      halt
      EOF
      grub-mkstandalone -O x86_64-efi -o BOOTX64.EFI "boot/grub/grub.cfg=grub.cfg"
      truncate -s 64M esp.img
      mkfs.vfat -F 32 -i 12345678 esp.img
      mmd -i esp.img ::EFI ::EFI/BOOT
      mcopy -i esp.img BOOTX64.EFI ::EFI/BOOT/BOOTX64.EFI
      printf 'Partition contents survive idr-wipe-local-vm.\n' > payload
      mcopy -i esp.img payload ::payload
      truncate -s 96M disk.raw
      sgdisk --disk-guid=11111111-2222-3333-4444-555555555555 \
        --new=1:2048:+64M --typecode=1:ef00 \
        --partition-guid=1:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee disk.raw
      dd if=esp.img of=disk.raw bs=1M seek=1 conv=notrunc status=none
      qemu-img convert -f raw -O qcow2 disk.raw $out/disk.qcow2
    '';

  # A fixed test host key makes the real installer's readiness deterministic.
  installer = import ../../../preset/base/qemu/installer.nix {
    pkgs =
      pkgs
      // {
        nixos = modules:
          pkgs.nixos (modules
            ++ [
              {
                environment.etc."ssh/idr-test-host-key" = {
                  source = keys.snakeOilEd25519PrivateKey;
                  mode = "0600";
                };
                services.openssh.hostKeys = lib.mkForce [
                  {
                    type = "ed25519";
                    path = "/etc/ssh/idr-test-host-key";
                  }
                ];
              }
            ]);
      };
    nixosImages = inputs.nixos-images;
    inherit machineId networkPrefix;
    qemuUdevRules = guest.config.system.build.idr.meta.disko.qemuUdevRules;
    sshPorts = [sshPort];
  };

  guest = pkgs.nixos {
    imports = builtins.attrValues self.modules.nixos;
    _module.args.inputs = inputs;
    networking.hostName = machineName;
    system.stateVersion = "26.05";
    idr.preset.base = {
      id = machineId;
      inputs.self = "/root/project";
    };
    services.openssh.ports = [sshPort];
    disko.devices.disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-eui.1122334455667788";
      imageName = "disk";
      imageSize = "96M";
      content = {
        type = "gpt";
        partitions.ESP = {
          size = "64M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
          };
        };
      };
    };
    idr.meta.preset.base.qemu = {
      installerIso = "${installer}/iso/nixos-installer-${pkgs.stdenv.hostPlatform.system}.iso";
      memorySize = 2048;
      vnc.enable = true;
      audio.enable = false;
      clipboard.enable = false;
      options = [
        "-fw_cfg"
        "name=opt/io.systemd.credentials/idr.qemu-ssh-key,string=${keys.snakeOilEd25519PublicKey}"
      ];
    };
  };
  runner = guest.config.system.build.idrQemu;
  disko = builtins.removeAttrs guest.config.system.build.idr.meta.disko ["self"];

  # Exercise the actual process definition and startup hook with one VM.
  qemuModule = import ../flake-module.nix {} {
    inherit lib;
    self.nixosConfigurations.${machineName} = {
      inherit pkgs;
      config = {
        system.build.idrQemu = runner;
        system.build.idr.meta.sshHostPublicKey = keys.snakeOilEd25519PublicKey;
        services.openssh = {
          enable = true;
          ports = [sshPort];
        };
        idr = {
          qemu.networkPrefix = networkPrefix;
          preset.base.id = machineId;
        };
      };
    };
  };
  qemuProcesses =
    (qemuModule.perSystem {
      inherit pkgs;
      system = pkgs.stdenv.hostPlatform.system;
    }).process-compose.idr.settings.processes;
  devshellModule = import ../../devshell/flake-module.nix {inherit inputs self;} {
    inherit lib inputs self;
    config.idr.projectName = "idr-qemu-test";
  };
  processCli =
    (devshellModule.perSystem {
      inherit pkgs;
      system = pkgs.stdenv.hostPlatform.system;
      config = {};
      self' = {};
    }).process-compose.idr.cli;
  processCompose = (import inputs.process-compose-flake.lib {inherit pkgs;}).makeProcessCompose {
    name = "idr";
    modules = [
      {
        cli = processCli;
        settings.processes = qemuProcesses;
      }
    ];
  };

  project = pkgs.runCommand "idr-qemu-test-project" {} ''
    mkdir -p $out
    cp ${pkgs.writeText "metadata.json" (builtins.toJSON {
      machine = machineName;
      system = pkgs.stdenv.hostPlatform.system;
      sshHostPublicKey = keys.snakeOilEd25519PublicKey;
      initrdHostPublicKey = null;
      initrdHostPublicKeys = [];
      initrdPort = sshPort;
      defaultSopsFile = null;
      inherit disko;
    })} $out/metadata.json
    cp ${pkgs.writeText "flake.nix" ''
      {
        inputs.nixpkgs = ${lib.generators.toPretty {} nixpkgsLock.original};
        outputs = {self, ...}: let
          meta = builtins.fromJSON (builtins.readFile ./metadata.json);
          profile = process: {path.idr = {inherit meta; qemuProcess = process;};};
        in {
          nixosConfigurations.${machineName}.config.system.build.idr = {inherit meta;};
          deploy = {
            sshUser = "root";
            nodes.${machineName} = {hostname = "${machineName}"; profiles.system = profile null;};
            nodes.vm-${machineName} = {hostname = "vm-${machineName}"; profiles.system = profile "vm-${machineName}";};
          };
        };
      }
    ''} $out/flake.nix
    cp ${pkgs.writeText "flake.lock" (builtins.toJSON {
      version = 7;
      root = "root";
      nodes = {
        root.inputs.nixpkgs = "nixpkgs";
        nixpkgs = nixpkgsLock;
      };
    })} $out/flake.lock
    echo .data > $out/.gitignore
  '';
  environment = pkgs.writers.writeNuBin "idr-test" ''
    use ${scripts}/idr-common.nu [host-socket-prefix]
    def --wrapped main [...args] {
      $env.PRJ_ROOT = "/root/project"
      $env.PRJ_DATA_DIR = "/root/project/.data"
      $env.IDR_WORKSPACE_ID = $env.IDR_WORKSPACE_ID? | default "42b08923"
      $env.PC_SOCKET_PATH = $env.PRJ_DATA_DIR | path join $"(host-socket-prefix 'pc').sock"
      cd $env.PRJ_ROOT
      exec ...$args
    }
  '';
in
  pkgs.testers.runNixOSTest {
    name = "idr-qemu-lifecycle";
    globalTimeout = 15 * 60;
    nodes.machine = {lib, ...}: {
      virtualisation = {
        cores = 4;
        memorySize = 4096;
        diskSize = 8192;
        useNixStoreImage = true;
        writableStore = true;
        writableStoreUseTmpfs = false;
        additionalPaths = [inputs.nixpkgs.outPath];
        qemu.options = ["-cpu" "host"];
      };
      nix.settings = {
        experimental-features = ["nix-command" "flakes"];
        substituters = lib.mkForce [];
        sandbox = true;
      };
      networking.useDHCP = false;
      environment.systemPackages =
        [
          environment
          processCompose
          runner
          commands.packages.idr-wipe-local-vm
          commands.packages.idr-serial
        ]
        ++ (with pkgs; [gitMinimal nushell qemu openssh jq python3]);
      environment.etc = {
        "idr-test-project".source = project;
        "idr-test-disk.qcow2".source = "${bootDisk}/disk.qcow2";
        "idr-test-key".source = keys.snakeOilEd25519PrivateKey;
        "idr-test-public-key".text = keys.snakeOilEd25519PublicKey;
        "idr-test-console.py".source = ./lifecycle/console.py;
      };
    };
    testScript = builtins.readFile ./lifecycle/test.py;
  }

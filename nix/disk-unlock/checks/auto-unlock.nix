{
  pkgs,
  inputs,
  self,
}: let
  inherit (pkgs) lib;
  keys = inputs.nixpkgs + /nixos/tests/initrd-network-ssh;
  clientAddress = "192.168.1.1";
  serverAddress = "192.168.1.2";
  machineId = "111111111111";
  serverId = "222222222222";
  memberName = "server-${serverId}";
  clientMemberName = "client-unlocker";
  hostPublicKey = lib.trim (builtins.readFile (keys + "/ssh_host_ed25519_key.pub"));
  unlockPublicKey = lib.trim (builtins.readFile (keys + "/id_ed25519.pub"));
  knownHosts = pkgs.writeText "test-known-hosts" "* ${hostPublicKey}\n";
  diskKey = pkgs.writeText "test-disk-key" "public-test-disk-passphrase";
  publicKeys = builtins.toFile "test-machine-public-keys.json" (builtins.toJSON {
    ssh_host_ed25519_key_pub_unencrypted = hostPublicKey;
    initrd_ssh_host_ed25519_key_pub_unencrypted = hostPublicKey;
  });
  containerImage = pkgs.dockerTools.buildLayeredImage {
    name = "idr-network-test";
    tag = "test";
    contents = [pkgs.busybox (pkgs.writeTextDir "www/index.html" "idr-network-ok\n")];
    config.Cmd = ["/bin/httpd" "-f" "-p" "[::]:8080" "-h" "/www"];
  };
  top = {
    inputs = inputs // {idr = self;};
    idr-lib =
      self.lib
      // {
        team = {
          ${memberName} = {
            system = true;
            groups = ["unlock-server"];
            hostname = serverAddress;
            sshPublicKey = unlockPublicKey;
            agePublicKey = "age1pmplerruvxzeaxv8fyj94pr9mq944hxpzfhse5ydjnwxd2x5pcwspak5pd";
          };
          ${clientMemberName} = {
            system = true;
            groups = ["unlock-server"];
            hostname = clientAddress;
            sshPublicKey = hostPublicKey;
          };
        };
      };
  };

  # These identities and passphrases are public fixtures used only by this test.
  fixtures =
    pkgs.runCommand "idr-auto-unlock-fixtures" {
      nativeBuildInputs = with pkgs; [jq sops ssh-to-age];
    } ''
      mkdir -p $out
      recipient="$(ssh-to-age < ${keys + "/ssh_host_ed25519_key.pub"})"
      jq -n --rawfile disk_key ${diskKey} \
        --arg hash ${builtins.hashString "sha256" "public-test-disk-passphrase"} \
        '{disk_key: $disk_key, disk_key_hash_unencrypted: $hash}' |
        sops encrypt --age "$recipient,${top.idr-lib.team.${memberName}.agePublicKey}" \
          --unencrypted-suffix _unencrypted --input-type json --output-type json \
          /dev/stdin > $out/disk-key.enc.json
    '';
  clientNode = client: advertisedKey:
    (inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [pkgs.stdenv.hostPlatform.system];
      imports = [(import ../../idr/deploy/flake-module.nix {inherit inputs self;})];
      flake = {
        nixosConfigurations.client = {
          inherit pkgs;
          # The initial server configuration represents an outdated host-key pin.
          config = lib.recursiveUpdate client {
            system.build.idr.meta.initrdHostPublicKey = advertisedKey;
          };
        };
        deploy = {
          # Initrd metadata must override the deployment's port and additional host trust.
          sshOpts = [
            "-p"
            "2200"
            "-o"
            "KnownHostsCommand=${pkgs.coreutils}/bin/cat ${knownHosts}"
          ];
          nodes.client.hostname = clientAddress;
        };
      };
    }).deploy.nodes.client;
in
  pkgs.testers.runNixOSTest {
    name = "idr-auto-unlock";
    globalTimeout = 10 * 60;
    node.pkgsReadOnly = false;

    defaults = {
      imports = [(lib.modules.importApply ../nixos-module.nix top)];
      virtualisation.memorySize = 1024;
      nix.settings.sandbox = true;
    };

    nodes.server = {nodes, ...}: {
      imports = [
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        inputs.impermanence.nixosModules.impermanence
        (lib.modules.importApply ../../preset/nixos-module.nix top)
        self.modules.nixos.secrets
      ];
      idr.preset.base = {
        id = serverId;
        inputs.self = self;
      };
      system.extraDependencies = lib.mkForce [];
      hardware.enableRedistributableFirmware = false;
      services.fail2ban.enable = false;
      boot.initrd.network.ssh.enable = false;
      users.allowNoPasswordLogin = true;
      virtualisation.memorySize = lib.mkForce 2048;
      system.switch.enable = true;
      sops.age = {
        keyFile = null;
        sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
      };
      sops.gnupg.sshKeyPaths = [];
      environment.systemPackages = [pkgs.netcat-openbsd pkgs.openssh pkgs.bind.dnsutils];
      environment.etc."test-container-image.tar.gz".source = containerImage;
      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = keys + "/id_ed25519";
        mode = "0600";
      };
      environment.etc."idr-test/known-hosts".text = "${clientAddress} ${hostPublicKey}\n";
      environment.etc."idr-test/client-key" = {
        source = keys + "/ssh_host_ed25519_key";
        mode = "0400";
      };
      services.openssh = {
        enable = true;
        hostKeys = [
          {
            type = "ed25519";
            path = "/etc/ssh/ssh_host_ed25519_key";
          }
        ];
      };
      idr.disk-unlock.server = {
        enable = true;
        timeout = 15;
        nodes = [(clientNode nodes.client.specialisation.encrypted.configuration unlockPublicKey)];
      };
      specialisation.correct-key.configuration.idr.disk-unlock.server.nodes =
        lib.mkForce [(clientNode nodes.client.specialisation.encrypted.configuration hostPublicKey)];
    };

    nodes.client = {
      imports = [
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        inputs.impermanence.nixosModules.impermanence
        (lib.modules.importApply ../../preset/nixos-module.nix top)
        self.modules.nixos.secrets
      ];
      idr.preset.base = {
        id = machineId;
        inputs.self = self;
        defaultSopsFile = publicKeys;
      };
      idr.disk-unlock.server = {
        enable = true;
        member = clientMemberName;
      };
      # Keep the test focused on boot, SSH, and secrets rather than offline builds.
      system.extraDependencies = lib.mkForce [];
      hardware.enableRedistributableFirmware = false;
      virtualisation.podman.enable = false;
      services.fail2ban.enable = false;
      users.allowNoPasswordLogin = true;
      virtualisation = {
        emptyDiskImages = [128];
        useBootLoader = true;
        useEFIBoot = true;
        mountHostNixStore = true;
      };
      boot.loader.grub.enable = lib.mkForce false;
      boot.loader.systemd-boot.enable = true;
      boot.loader.timeout = 0;
      boot.initrd.systemd.enable = true;
      boot.initrd.network.ssh.enable = false;
      environment.systemPackages = [pkgs.cryptsetup];
      environment.etc."ssh/ssh_host_ed25519_key" = {
        source = keys + "/ssh_host_ed25519_key";
        mode = "0600";
      };
      services.openssh.hostKeys = lib.mkForce [
        {
          type = "ed25519";
          path = "/etc/ssh/ssh_host_ed25519_key";
        }
      ];
      sops.age = {
        keyFile = null;
        sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
      };
      sops.gnupg.sshKeyPaths = [];

      specialisation.encrypted.configuration = {
        idr.preset.base.preFormatFiles."/disk-key.txt" = {
          sopsFile = fixtures + "/disk-key.enc.json";
          key = "disk_key";
        };
        idr.disk-unlock.client.interval = 2;
        disko.devices.disk.system = {
          type = "disk";
          device = "/dev/vdb";
          content = {
            type = "luks";
            name = "cryptroot";
            passwordFile = "/disk-key.txt";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
        virtualisation.rootDevice = "/dev/mapper/cryptroot";
        boot.initrd.luks.devices = lib.mkVMOverride {
          cryptroot.device = "/dev/vdb";
        };
        boot.initrd.availableKernelModules = ["virtio_net" "qemu_fw_cfg"];
        boot.initrd.systemd.network.networks."10-client" = {
          matchConfig.Name = "eth1";
          address = ["${clientAddress}/24"];
        };
        boot.initrd.network.ssh = {
          enable = lib.mkForce true;
          port = 2222;
          hostKeys = lib.mkForce ["/etc/ssh/ssh_host_ed25519_key"];
        };
      };
    };

    testScript = {nodes, ...}:
      ''
        encrypted = "${nodes.client.specialisation.encrypted.configuration.system.build.toplevel}"
        correct_key = "${nodes.server.specialisation.correct-key.configuration.system.build.toplevel}"
        disk_key = "${diskKey}"
        client_address = "${clientAddress}"
        server_address = "${serverAddress}"
        dns_gateway = "${nodes.server.idr.preset.base.podman.IPv4.gateway}"
        dns_port = ${toString nodes.server.virtualisation.containers.containersConf.settings.network.dns_bind_port}
        unlock_key = "/etc/ssh/ssh_host_ed25519_key"
        request_unit = "idr-request-disk-unlock-${memberName}"
        self_request_unit = "idr-request-disk-unlock-${clientMemberName}"
      ''
      + builtins.readFile ./auto-unlock/test.py;
  }

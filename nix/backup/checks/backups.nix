{
  pkgs,
  inputs,
  self,
}: let
  inherit (pkgs) lib;
  keys = inputs.nixpkgs + /nixos/tests/initrd-network-ssh;
  sourcePublic = lib.trim (builtins.readFile (keys + "/ssh_host_ed25519_key.pub"));
  backupPublic = lib.trim (builtins.readFile (keys + "/id_ed25519.pub"));
  sourceId = "111111111111";
  backupId = "222222222222";
  sourceAddress = "192.168.1.2";
  sourceLocal = "fd3e:aacc:e60e:42b0:8923:1111:1111:1111";
  backupLocal = "fd3e:aacc:e60e:42b0:8923:2222:2222:2222";
  top = {
    inputs = inputs // {idr = self;};
    idr-lib =
      self.lib
      // {
        team."backup-${backupId}" = {
          system = true;
          groups = ["backup-server"];
          sshPublicKey = backupPublic;
        };
      };
  };
  publicKeys = public:
    builtins.toFile "backup-test-public-key.json" (builtins.toJSON {
      ssh_host_ed25519_key_pub_unencrypted = public;
    });
  sourceNode = source: backup: public: host: sshOpts:
    (inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [pkgs.stdenv.hostPlatform.system];
      imports = [(import ../../idr/deploy/flake-module.nix {inherit inputs self;})];
      flake = {
        nixosConfigurations = {
          source = {
            inherit pkgs;
            config = lib.recursiveUpdate source {system.build.idr.meta.sshHostPublicKey = public;};
          };
          backup = {
            inherit pkgs;
            config = backup;
          };
        };
        deploy = {
          inherit sshOpts;
          nodes.source.hostname = host;
        };
      };
    }).deploy.nodes.source;
  storage = pool: {
    disko.devices = {
      disk.storage = {
        type = "disk";
        device = "/dev/vdb";
        content = {
          type = "zfs";
          inherit pool;
        };
      };
      zpool.${pool} = {
        type = "zpool";
        rootFsOptions.mountpoint = "none";
      };
    };
    systemd.services.test-pool = {
      wantedBy = ["zfs-import.target"];
      before = ["zfs-import.target"];
      after = ["systemd-modules-load.service" "dev-vdb.device"];
      requires = ["dev-vdb.device"];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if ! /run/booted-system/sw/bin/zpool list ${pool}; then
          /run/booted-system/sw/bin/zpool import -d /dev/vdb ${pool} ||
            /run/booted-system/sw/bin/zpool create -f -m none ${pool} /dev/vdb
        fi
      '';
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "idr-backups";
    globalTimeout = 10 * 60;
    node.pkgsReadOnly = false;
    defaults = {
      imports = [
        inputs.disko.nixosModules.disko
        inputs.disko-zfs.nixosModules.default
        inputs.sops-nix.nixosModules.sops
        inputs.impermanence.nixosModules.impermanence
        (lib.modules.importApply ../../preset/nixos-module.nix top)
        (lib.modules.importApply ../nixos-module.nix top)
      ];
      system.extraDependencies = lib.mkForce [];
      hardware.enableRedistributableFirmware = false;
      virtualisation.podman.enable = false;
      services.fail2ban.enable = false;
      users.allowNoPasswordLogin = true;
      users.users.root.hashedPassword = lib.mkForce "!";
      boot.initrd.network.ssh.enable = false;
      boot.loader.grub.enable = lib.mkForce false;
      boot.supportedFilesystems = ["zfs"];
      boot.kernelModules = ["zfs"];
      services.openssh.settings.PerSourcePenalties = "no";
      system.switch.enable = true;
      nix.settings.sandbox = true;
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      virtualisation.emptyDiskImages = [512];
      services.sanoid.interval = "daily";
      services.sanoid.extraArgs = ["--force-update"];
      environment.systemPackages = [pkgs.openssh];
    };

    nodes.source = {
      imports = [(storage "src")];
      idr.preset.base = {
        id = sourceId;
        inputs.self = self;
        defaultSopsFile = publicKeys sourcePublic;
      };
      services.openssh = {
        ports = [2200 2222];
        openFirewall = lib.mkForce false;
        hostKeys = lib.mkForce [
          {
            type = "ed25519";
            path = "/etc/ssh/source-key";
          }
        ];
      };
      environment.etc."ssh/source-key" = {
        source = keys + "/ssh_host_ed25519_key";
        mode = "0600";
      };
      networking.firewall.allowedTCPPorts = [2222];
      networking.firewall.extraInputRules = "ip6 saddr fd3e:aacc:e60e::/48 tcp dport 2200 accept";
      networking.interfaces.eth1.ipv6.addresses = [
        {
          address = sourceLocal;
          prefixLength = 48;
        }
      ];
      disko.devices.zpool.src.datasets = {
        data = {
          type = "zfs_fs";
          options.mountpoint = "/source-data";
          options.compression = "zstd";
        };
        local = {
          type = "zfs_fs";
          options."syncoid:sync" = "false";
        };
        "local/root" = {
          type = "zfs_fs";
          options."idr:snapshots" = "false";
        };
        "local/nix" = {
          type = "zfs_fs";
          options."idr:snapshots" = "false";
        };
        "local/nix/cache".type = "zfs_fs";
        "local/persist".type = "zfs_fs";
        volume = {
          type = "zfs_volume";
          size = "16M";
          options."idr:snapshots" = "false";
        };
      };
      systemd.services.test-pool.postStart = ''
        if ! /run/booted-system/sw/bin/zfs list src/volume; then
          /run/booted-system/sw/bin/zfs create -o idr:snapshots=false -V 16M src/volume
        fi
      '';
      specialisation.disabled.configuration.idr.backup.client.enable = lib.mkForce false;
      specialisation.datasets.configuration = {
        disko.devices.zpool.src.datasets = {
          data.options.compression = lib.mkForce "zstd-5";
          added = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/added";
          };
        };
        # The VM module replaces the normal filesystem declarations.
        virtualisation.fileSystems."/added" = {
          device = "src/added";
          fsType = "zfs";
        };
      };
    };

    nodes.backup = {nodes, ...}: {
      imports = [(storage "dst")];
      idr.preset.base = {
        id = backupId;
        inputs.self = self;
        defaultSopsFile = publicKeys backupPublic;
      };
      services.openssh.hostKeys = lib.mkForce [
        {
          type = "ed25519";
          path = "/etc/ssh/backup-key";
        }
      ];
      environment.etc = {
        "ssh/backup-key" = {
          source = keys + "/id_ed25519";
          mode = "0600";
        };
        "test-rogue-key" = {
          source = keys + "/ssh_host_ed25519_key";
          mode = "0600";
        };
        "test-known-hosts".text = "* ${sourcePublic}\n";
      };
      networking.interfaces.eth1.ipv6.addresses = [
        {
          address = backupLocal;
          prefixLength = 48;
        }
      ];
      idr.backup.server = {
        enable = true;
        dataset = "dst/archive";
        interval = "daily";
        nodes = [(sourceNode nodes.source nodes.backup sourcePublic sourceAddress ["-p" "2222"])];
      };
      specialisation.wrong-key.configuration.idr.backup.server.nodes = lib.mkForce [
        (sourceNode nodes.source nodes.backup backupPublic sourceAddress ["-p" "2222" "-o" "StrictHostKeyChecking=no"])
      ];
      specialisation.local.configuration.idr.backup.server.nodes = lib.mkForce [
        (sourceNode nodes.source nodes.backup sourcePublic "192.0.2.254" ["-p" "9" "-o" "ProxyCommand=false"])
      ];
    };

    testScript =
      ''
        source_address = "${sourceAddress}"
        backup_unit = "idr-backup-source-${sourceId}.service"
        destination = "dst/archive/source-${sourceId}/src"
      ''
      + builtins.readFile ./backups/test.py;
  }

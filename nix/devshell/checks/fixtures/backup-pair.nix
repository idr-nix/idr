{
  top,
  pkgs,
}: {lib, ...}: let
  keys = import "${top.inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs;
  sourceKey = lib.trim (builtins.readFile ./backup/source_ed25519.pub);
in {
  imports = [top.self.modules.nixosTest.disk-storage];

  node.pkgsReadOnly = false;
  globalTimeout = 15 * 60;

  nodes = {
    source = {config, ...}: let
      cfg = config.test.backup;
      sourceTop =
        top
        // {
          idr-lib =
            top.idr-lib
            // {
              team.backup-machine-bac000000002 = {
                system = true;
                groups = ["backup-server"];
                sshPublicKey = cfg.authorizedPublicKey;
              };
            };
        };
    in {
      imports = [(lib.modules.importApply ./backup-machine.nix sourceTop)];
      options.test.backup = {
        authorizedPublicKey = lib.mkOption {
          type = lib.types.str;
          default = keys.snakeOilEd25519PublicKey;
        };
        hostPublicKey = lib.mkOption {
          type = lib.types.str;
          default = sourceKey;
        };
        hostKeyPath = lib.mkOption {
          type = lib.types.str;
          default = "/etc/ssh/source-key";
        };
      };
      config = {
        idr.preset.base = {
          id = "bac000000001";
          defaultSopsFile = builtins.toFile "backup-source-metadata.json" (builtins.toJSON {
            ssh_host_ed25519_key_pub_unencrypted = cfg.hostPublicKey;
          });
        };
        services.openssh = {
          ports = [2222];
          hostKeys = lib.mkForce [
            {
              type = "ed25519";
              path = cfg.hostKeyPath;
            }
          ];
        };
        systemd.tmpfiles.rules = [
          "C /etc/ssh/source-key 0600 root root - ${./backup/source_ed25519}"
          "C /etc/ssh/source-rotated-key 0600 root root - ${./backup/source_rotated_ed25519}"
        ];
        systemd.services.sshd-keygen.after = ["systemd-tmpfiles-setup.service"];
        disko.devices.zpool.p1.datasets.application = {
          type = "zfs_fs";
          mountpoint = "/srv/application";
        };
        systemd.services.test-data-disk.postStart = ''
          /run/booted-system/sw/bin/zfs mount p1/application
          printf 'initial application data\n' > /srv/application/message
          /run/booted-system/sw/bin/zfs snapshot -r p1@test-initial
        '';
      };
    };

    server = {
      config,
      nodes,
      ...
    }: let
      cfg = config.test.backup;
    in {
      imports = [(lib.modules.importApply ./backup-machine.nix top)];
      options.test.backup = {
        sourceMetadata = lib.mkOption {
          type = lib.types.raw;
          default = nodes.source.system.build.idr.meta;
        };
        hostKeyPath = lib.mkOption {
          type = lib.types.str;
          default = "/etc/ssh/server-key";
        };
        hostname = lib.mkOption {
          type = lib.types.str;
          default = "source";
        };
        sshOptions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["-p" "2222"];
        };
      };
      config = {
        idr.preset.base.id = "bac000000002";
        idr.backup.client.enable = false;
        idr.backup.server = {
          enable = true;
          dataset = "p1/backups";
          interval = "2099-01-01 00:00:00";
          nodes = [
            {
              hostname = cfg.hostname;
              sshOpts = cfg.sshOptions;
              profiles.system.path.idr = {
                meta = cfg.sourceMetadata;
                globalSshOpts = [];
              };
            }
          ];
        };
        services.openssh.hostKeys = lib.mkForce [
          {
            type = "ed25519";
            path = cfg.hostKeyPath;
          }
        ];
        systemd.tmpfiles.rules = [
          "C /etc/ssh/server-key 0600 root root - ${keys.snakeOilEd25519PrivateKey}"
          "C /etc/ssh/server-rotated-key 0600 root root - ${./backup/server_rotated_ed25519}"
          "d /mnt/backup 0755 root root -"
        ];
        systemd.services.sshd-keygen.after = ["systemd-tmpfiles-setup.service"];
      };
    };
  };
}

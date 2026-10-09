top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks = {
      automatic-disk-unlock = pkgs.testers.runNixOSTest ({nodes, ...}: let
        fixtures = ./fixtures/disk-unlock;
        clientId = "123456abcdef";
        serverMember = "server-abcdef123456";
        serverKey = "/etc/ssh/ssh_host_ed25519_key";
        team = {
          ${serverMember} = {
            system = true;
            groups = ["unlock-server"];
            hostname = nodes.server.networking.primaryIPAddress;
            port = 64997;
            sshPublicKey = lib.fileContents (fixtures + /server-key.pub);
            agePublicKey = lib.fileContents (fixtures + /server-age.pub);
          };
        };
        unlockModule =
          lib.modules.importApply ../../disk-unlock/nixos-module.nix
          (top // {idr-lib = top.idr-lib // {inherit team;};});
        # The server consumes these public deploy-rs profile fields; no local
        # QEMU process or runner participates in this production unlock flow.
        clientNode = {
          hostname = nodes.client.networking.primaryIPAddress;
          profiles.system.path.idr = {
            qemuProcess = null;
            globalSshOpts = [];
            meta = {
              machine = "client";
              machineId = clientId;
              initrdPort = 2222;
              initrdHostPublicKey = lib.fileContents (fixtures + /client-initrd-key.pub);
              disko.preFormatFiles."/disk-key.txt" = {
                sopsFile = fixtures + /disk-key.enc.json;
                key = "disk_key";
              };
            };
          };
        };
      in {
        imports = [
          (lib.modules.importApply ../../testing/arm-image-builder.nix {})
          top.self.modules.nixosTest.disk-storage
        ];
        name = "automatic-disk-unlock";
        globalTimeout = 10 * 60;
        defaults = {
          imports = [unlockModule top.self.modules.nixos.sops];
          # This direct service test supplies the machine ID normally declared
          # by the base preset, without enabling unrelated base services.
          options.idr.preset.base.id = lib.mkOption {
            type = lib.types.str;
            default = clientId;
          };
          config = {
            idr.disk-unlock.client.enable = lib.mkDefault false;
            networking.useDHCP = false;
            virtualisation = {
              cores = 2;
              memorySize = 2048;
            };
          };
        };

        nodes.server = {pkgs, ...}: {
          services.openssh = {
            enable = true;
            hostKeys = [
              {
                path = serverKey;
                type = "ed25519";
              }
            ];
          };
          environment.etc."ssh/ssh_host_ed25519_key" = {
            source = fixtures + /server-key;
            mode = "0600";
          };
          sops = {
            useSystemdActivation = true;
            age.sshKeyPaths = [serverKey];
            gnupg.sshKeyPaths = [];
          };
          idr.disk-unlock.server = {
            enable = true;
            member = serverMember;
            nodes = [
              clientNode
              (lib.recursiveUpdate clientNode {
                profiles.system.path.idr = {
                  qemuProcess = "vm-client";
                  meta.machine = "vm-client";
                };
              })
              (lib.recursiveUpdate clientNode {
                profiles.system.path.idr.meta = {
                  machine = "no-initrd-ssh";
                  initrdHostPublicKey = null;
                };
              })
            ];
          };
          environment.systemPackages = [pkgs.netcat];
        };

        nodes.client = {pkgs, ...}: {
          virtualisation = {
            emptyDiskImages = [512];
            useBootLoader = true;
            useEFIBoot = true;
            mountHostNixStore = true;
          };
          boot.loader.systemd-boot.enable = true;
          boot.initrd.systemd.enable = true;
          environment.etc."ssh/initrd_host_ed25519_key" = {
            source = fixtures + /client-initrd-key;
            mode = "0600";
          };
          services.openssh = {
            enable = true;
            settings = {
              PasswordAuthentication = false;
              KbdInteractiveAuthentication = false;
            };
          };
          specialisation.encrypted.configuration = {
            idr.disk-unlock.client = {
              enable = true;
              interval = 2;
            };
            boot.initrd = {
              luks.devices = lib.mkVMOverride {
                cryptroot.device = "/dev/vdb";
              };
              network.ssh = {
                port = 2222;
                hostKeys = ["/etc/ssh/initrd_host_ed25519_key"];
              };
              systemd.network.networks."10-test-network" = {
                matchConfig.Name = "eth1";
                address = ["${nodes.client.networking.primaryIPAddress}/24"];
              };
            };
            virtualisation.rootDevice = "/dev/mapper/cryptroot";
            systemd.services.prepare-encrypted-root.enable = false;
          };

          # Prepare a fresh encrypted root and its boot entry declaratively.
          # No passphrase file or alternate unlock method goes into its initrd.
          systemd.services.prepare-encrypted-root = {
            wantedBy = ["multi-user.target"];
            after = ["local-fs.target"];
            path = [pkgs.cryptsetup pkgs.e2fsprogs pkgs.util-linux pkgs.systemd];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              printf %s public-idr-disk-unlock-test-passphrase | cryptsetup luksFormat -q --iter-time=1 --key-file - /dev/vdb
              printf %s public-idr-disk-unlock-test-passphrase | cryptsetup luksOpen --key-file - /dev/vdb cryptroot
              mkfs.ext4 -q /dev/mapper/cryptroot
              mkdir -p /mnt/encrypted-root
              mount /dev/mapper/cryptroot /mnt/encrypted-root
              printf 'persisted on the encrypted root\n' > /mnt/encrypted-root/unlock-test-marker
              umount /mnt/encrypted-root
              cryptsetup close cryptroot
              /run/current-system/specialisation/encrypted/bin/switch-to-configuration boot
              entry=(/boot/loader/entries/*-specialisation-encrypted.conf)
              test "''${#entry[@]}" -eq 1
              bootctl set-default "''${entry[0]##*/}"
            '';
          };
        };

        testScript = ''
          start_all()
          server.wait_for_unit("idr-disk-unlock.socket")
          server.wait_for_unit("sops-install-secrets.service")
          client.wait_for_unit("prepare-encrypted-root.service")

          with subtest("only production targets with SSH-unlock metadata receive disk keys"):
              for target in ["vm-client", "no-initrd-ssh"]:
                  server.fail(f"test -e /run/secrets/idr-disk-unlock-{target}-${clientId}")

          with subtest("boot waits for an available unlock server"):
              server.succeed("systemctl stop idr-disk-unlock.socket")
              client.shutdown()
              client.start()
              client.wait_for_console_text("Please enter passphrase for disk cryptroot")
              server.wait_until_succeeds("nc -z -w 2 client 2222")
              server.fail("nc -z -w 2 client 22")

          with subtest("initrd retries and the server decrypts and sends the authorized disk key"):
              server.succeed("systemctl start idr-disk-unlock.socket")
              client.wait_for_unit("multi-user.target")
              assert client.succeed("findmnt -n -o SOURCE /").strip() == "/dev/mapper/cryptroot"
              assert client.succeed("cat /unlock-test-marker").strip() == "persisted on the encrypted root"
              server.wait_until_succeeds(
                  "journalctl -u 'idr-disk-unlock@*' --no-pager | grep -F 'Sent disk key to client-${clientId}.'"
              )

          with subtest("the unlock identity does not grant ordinary root SSH access"):
              client.wait_for_unit("sshd.service")
              status, output = server.execute(
                  "ssh -F /dev/null -i ${serverKey} -o BatchMode=yes -o IdentitiesOnly=yes "
                  "-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 root@client true 2>&1"
              )
              assert status == 255 and "Permission denied (publickey" in output, output
        '';
      });
    };
  };
}

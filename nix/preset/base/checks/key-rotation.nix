{
  pkgs,
  inputs,
  self,
  ...
}: let
  inherit (pkgs) lib;
  # Synthetic identities and passwords, intentionally public test fixtures.
  fixtures = ./key-rotation;
  deployProfiles = config: let
    deployment = inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [pkgs.stdenv.hostPlatform.system];
      imports = [(import ../../../idr/deploy/flake-module.nix {inherit inputs self;})];
      flake.nixosConfigurations = {
        base = {inherit config pkgs;};
        rotated = {
          inherit pkgs;
          config = config.specialisation.rotated.configuration;
        };
        same-key = {
          inherit pkgs;
          config = config.specialisation.same-key.configuration;
        };
      };
    };
  in
    lib.mapAttrs (_: node: node.profiles.system.path) deployment.deploy.nodes;
  deploymentFlake = config:
    pkgs.writeText "rotation-deployment-flake.nix" ''
      {
        outputs = _: let
          # The enclosing NixOS test supplies these immutable store inputs.
          storeInput = path: builtins.appendContext path { "''${path}" = { path = true; }; };
          prebuilt = storeInput "${(deployProfiles config).same-key}";
          coreutils = storeInput "${pkgs.coreutils}";
        in {
          deploy.nodes.machine = {
            hostname = "localhost";
            sshUser = "root";
            sshOpts = [
              "-i" "/persist/ssh/host-a"
              "-o" "UserKnownHostsFile=/etc/idr-test/known-hosts"
              "-o" "StrictHostKeyChecking=yes"
            ];
            fastConnection = true;
            activationTimeout = 120;
            confirmTimeout = 60;
            profiles.system = {
              user = "root";
              # Exercise native Nix builds without rebuilding the whole system.
              path = builtins.derivation {
                name = "prebuilt-test-system";
                system = "${pkgs.stdenv.hostPlatform.system}";
                builder = "''${coreutils}/bin/ln";
                args = ["-s" "''${prebuilt}" (builtins.placeholder "out")];
              };
            };
          };
        };
      }
    '';
  key = name: pkgs.writeText "test-disk-key-${name}" "test-disk-key-${name}";
  disk = name: passwordFile: {
    type = "disk";
    device = "/dev/loop${name}";
    content = {
      type = "luks";
      name = "test-${name}";
      inherit passwordFile;
      # These disposable volumes are formatted by the test after initrd.
      settings.crypttabExtraOpts = ["noauto"];
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "idr-disk-key-rotation";
    globalTimeout = 15 * 60;

    nodes.machine = {
      config,
      lib,
      pkgs,
      ...
    }: {
      imports = [
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        (import ../key-rotation.nix {inherit inputs;})
      ];

      # Import the rotation module on its own, without unrelated base services.
      options.idr.preset = lib.mkOption {type = lib.types.attrsOf lib.types.anything;};

      config = {
        idr.preset = {
          base = {
            enable = true;
            preFormatFiles."/disk-key.txt" = {
              path = "/disk-key.txt";
              sopsFile = fixtures + "/a.sops.json";
              key = "disk_key";
            };
          };
          impermanence = {
            enable = true;
            persistDir = "/persist";
          };
        };

        disko.devices.disk = {
          first = disk "0" "/disk-key.txt";
          second = lib.recursiveUpdate (disk "1" "/disk-key.txt") {
            content.settings.header = "/var/lib/test-disks/1.header";
          };
          independent = disk "2" "/another-key.txt";
        };
        # This test VM boots its kernel directly and has no installed bootloader.
        boot.loader.grub.enable = lib.mkForce false;
        boot.initrd.systemd.enable = true;
        # The VM test module otherwise discards all declared LUKS devices.
        boot.initrd.luks.devices = lib.mkOverride 0 (lib.mapAttrs' (_: disk:
          lib.nameValuePair disk.content.name ({inherit (disk.content) device;} // disk.content.settings))
        config.disko.devices.disk);
        boot.kernelModules = ["loop"];

        sops.age = {
          keyFile = null;
          sshKeyPaths = ["/persist/ssh/host-a"];
        };
        system.activationScripts.test-host-keys = {
          deps = ["specialfs"];
          text = ''
            install -d -m 0700 /persist/ssh
            install -m 0600 ${fixtures + "/host-a"} /persist/ssh/host-a
            install -m 0600 ${fixtures + "/host-b"} /persist/ssh/host-b
          '';
        };
        system.activationScripts.setupSecrets.deps = ["test-host-keys"];

        systemd.services.test-disks = {
          before = ["idr-disk-keys.service"];
          requiredBy = ["idr-disk-keys.service"];
          after = ["local-fs.target"];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writers.writeNu "prepare-test-disks" ''
              mkdir /var/lib/test-disks
              for index in 0..2 {
                let device = $"/dev/loop($index)"
                let image = $"/var/lib/test-disks/($index).img"
                let header = if $index == 1 { [--header /var/lib/test-disks/1.header] } else { [] }
                truncate -s 64M $image
                losetup $device $image
                cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file ${key "a"} ...$header $device

                # LUKS2 metadata distinguishes this manual key from managed keys.
                if $index < 2 {
                  cryptsetup luksAddKey --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file ${key "a"} ...$header $device ${key "recovery"}
                }
              }
            '';
          };
          path = [pkgs.coreutils pkgs.cryptsetup pkgs.util-linux];
        };

        systemd.services.test-activation = {
          wantedBy = ["multi-user.target"];
          restartTriggers = [config.idr.preset.base.preFormatFiles."/disk-key.txt".sopsFile];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/test ! -e /run/fail-activation";
          };
        };

        specialisation = {
          same-key.configuration = {
            idr.preset.base.preFormatFiles."/disk-key.txt".sopsFile = lib.mkForce (fixtures + "/same-a.sops.json");
            sops.age.sshKeyPaths = lib.mkForce ["/persist/ssh/host-b"];
          };
          rotated.configuration = {
            idr.preset.base.preFormatFiles."/disk-key.txt".sopsFile = lib.mkForce (fixtures + "/b.sops.json");
            sops.age.sshKeyPaths = lib.mkForce ["/persist/ssh/host-b"];
          };
        };

        environment.etc = {
          "idr-test/key-a".source = key "a";
          "idr-test/key-b".source = key "b";
          "idr-test/key-recovery".source = key "recovery";
          "idr-test/known-hosts".text = "localhost ${builtins.readFile (fixtures + "/host-a.pub")}";
        };
        services.openssh = {
          enable = true;
          hostKeys = [
            {
              type = "ed25519";
              path = "/persist/ssh/host-a";
            }
          ];
        };
        users.users.root.openssh.authorizedKeys.keyFiles = [(fixtures + "/host-a.pub")];
        environment.systemPackages = [
          pkgs.cryptsetup
          pkgs.keyutils
          inputs.deploy-rs.packages.${pkgs.stdenv.hostPlatform.system}.deploy-rs
        ];
        nix.settings = {
          experimental-features = ["nix-command" "flakes"];
          sandbox = true;
          substituters = lib.mkForce [];
        };
        virtualisation = {
          additionalPaths = builtins.attrValues (deployProfiles config);
          memorySize = 2048;
          cores = 2;
          writableStoreUseTmpfs = false;
        };
      };
    };

    testScript = {nodes, ...}: ''
      profiles = ${builtins.toJSON (lib.mapAttrs (_: toString) (deployProfiles nodes.machine))}
      deployment_flake = "${deploymentFlake nodes.machine}"
      ${builtins.readFile ./key-rotation/test.py}
    '';
  }

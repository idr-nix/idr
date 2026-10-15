top: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.microvmGuest;
  platform = pkgs.stdenv.hostPlatform;
  console =
    if platform.isAarch64
    then "ttyAMA0,115200n8"
    else if platform.isx86
    then "ttyS0,115200n8"
    else "hvc0";
in {
  key = toString ./guest.nix;

  imports = [
    (lib.modules.importApply ../preset/impermanence/impermanence.nix top)
    ./deployment-guest.nix
  ];

  options.idr.microvmGuest = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the disk-booted Cloud Hypervisor guest profile.";
    };

    diskSizeMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 64 * 1024;
      example = 128 * 1024;
      description = ''
        Size of the initial guest disk image in MiB. The image contains an EFI
        system partition and Btrfs subvolumes for the ephemeral root, private
        Nix store and persistent state. Changing this does not resize an
        existing host volume.
      '';
    };

    earlyoom.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run earlyoom inside the guest to terminate processes under memory
        pressure. This is best-effort recovery, not a guarantee that a balloon
        target can be reached.
      '';
    };

    nvidia.enable = lib.mkEnableOption "headless NVIDIA drivers for CUDA workloads";

    network.ipv4Address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.1.0.2";
      description = "IPv4 reservation assigned by idr-mk-machine and served by the MicroVM host's DHCP server.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.diskSizeMiB >= 2048;
          message = "microvmGuest.diskSizeMiB must leave room for a 1 GiB EFI partition and the guest root filesystem.";
        }
      ];

      environment.etc."idr-microvm-identity".text = config.idr.preset.base.id;

      idr.preset.impermanence.rootSubvolume = "@root";
      fileSystems."/".autoResize = lib.mkDefault true;
      disko.imageBuilder.extraRootModules = ["btrfs"];

      disko.devices.disk.system = {
        type = "disk";
        device = "/dev/disk/by-id/virtio-idr-system";
        imageName = "system";
        imageSize = "${toString cfg.diskSizeMiB}M";
        content = {
          type = "gpt";
          partitions = {
            esp = {
              priority = 1;
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = ["noatime" "umask=0077"];
              };
            };
            root = {
              priority = 2;
              size = "100%";
              content = {
                type = "btrfs";
                subvolumes = {
                  "@root" = {
                    mountpoint = "/";
                    mountOptions = ["noatime"];
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = ["noatime"];
                  };
                  "@persist" = {
                    mountpoint = config.idr.preset.impermanence.persistDir;
                    mountOptions = ["noatime"];
                  };
                };
              };
            };
          };
        };
      };

      boot = {
        growPartition = lib.mkDefault true;
        loader = {
          systemd-boot.enable = lib.mkDefault true;
          systemd-boot.configurationLimit = lib.mkDefault 20;
          # IDR's base preset selects GRUB when Disko disks are present.
          grub.enable = false;
          efi.canTouchEfiVariables = lib.mkDefault false;
        };
        initrd = {
          systemd.enable = lib.mkDefault true;
          # The unencrypted boot disk needs no initrd network or remote unlock.
          systemd.network.enable = lib.mkOverride 900 false;
          network.enable = lib.mkOverride 900 false;
          network.ssh.enable = lib.mkOverride 900 false;
          availableKernelModules = [
            "virtio_pci"
            "virtio_blk"
            "virtio_net"
            "virtio_console"
            "virtio_rng"
            "virtiofs"
          ];
          # DMA translations must exist before a passed-through driver probes.
          kernelModules = ["virtio_iommu"];
        };
        kernelModules = ["virtio_balloon"];
        kernelParams = [
          "console=${console}"
          "iommu.passthrough=0"
          "iommu.strict=1"
        ];
        tmp.useTmpfs = lib.mkDefault false;
      };

      # Guest generations and boot entries are updated by ordinary NixOS tools.
      nix.enable = lib.mkDefault true;
      system.switch.enable = lib.mkDefault true;
      services.fstrim.enable = lib.mkDefault true;
      services.openssh.enable = lib.mkDefault true;
      systemd.generators.systemd-ssh-generator = "/dev/null";
      services.openssh.hostKeys = lib.mkDefault [
        {
          type = "ed25519";
          path = "${config.idr.preset.impermanence.persistDir}/etc/ssh/ssh_host_ed25519_key";
        }
      ];
      networking.useNetworkd = lib.mkDefault true;
      systemd.network.networks."50-idr-microvm" = {
        matchConfig.Driver = "virtio_net";
        networkConfig = {
          DHCP = "yes";
          IPv6AcceptRA = true;
          IPv6PrivacyExtensions = false;
          IPv6LinkLocalAddressGenerationMode = "eui64";
          MulticastDNS = false;
          LLMNR = false;
        };
        dhcpV4Config.ClientIdentifier = "mac";
        dhcpV6Config = {
          DUIDType = "link-layer";
          WithoutRA = "solicit";
        };
        ipv6AcceptRAConfig.UseAutonomousPrefix = false;
        linkConfig.RequiredForOnline = false;
      };
    }

    (lib.mkIf cfg.earlyoom.enable {
      systemd.oomd.enable = lib.mkDefault false;
      services.earlyoom = {
        enable = lib.mkDefault true;
        freeMemThreshold = lib.mkDefault 5;
        freeMemKillThreshold = lib.mkDefault 2;
        # Balloon pressure must not wait for a large guest swap to fill first.
        freeSwapThreshold = lib.mkDefault 100;
        freeSwapKillThreshold = lib.mkDefault 100;
        extraArgs = lib.mkDefault [
          "--avoid"
          "^(systemd|systemd-.+|sshd|dbus-daemon|dbus-broker|nix-daemon)$"
          "--prefer"
          "^(cc1|cc1plus|rustc|ld|ld.lld|lto1)$"
        ];
      };
    })

    (lib.mkIf cfg.nvidia.enable {
      nixpkgs.config.allowUnfreePredicate =
        lib.mkDefault (package:
          lib.hasPrefix "nvidia" (lib.getName package));
      services.xserver.videoDrivers = lib.mkDefault ["nvidia"];
      hardware.graphics.enable = lib.mkDefault true;
      hardware.nvidia = {
        open = lib.mkDefault true;
        modesetting.enable = lib.mkDefault false;
        nvidiaSettings = lib.mkDefault false;
        videoAcceleration = lib.mkDefault false;
      };
    })
  ]);
}

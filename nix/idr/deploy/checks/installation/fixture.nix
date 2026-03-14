{
  pkgs,
  disko,
  allowDiscards ? false,
  hardwareReport ? null,
}: let
  system = pkgs.nixos {
    imports = [disko.nixosModules.disko];
    system.stateVersion = "26.05";
    networking.hostName = "installed";
    documentation.enable = false;
    environment.etc = pkgs.lib.optionalAttrs (hardwareReport != null) {
      "fixture-hardware-report.json".source = builtins.path {
        path = hardwareReport;
        name = "fixture-hardware-report.json";
      };
    };
    boot = {
      initrd.availableKernelModules = ["virtio_pci" "virtio_blk"];
      loader.grub = {
        enable = true;
      };
    };
    disko.devices.disk.system = {
      type = "disk";
      device = "/dev/disk/by-id/virtio-installation-target";
      content = {
        type = "gpt";
        partitions = {
          bios = {
            size = "1M";
            type = "EF02";
          };
          boot = {
            size = "256M";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/boot";
            };
          };
          root = {
            size = "100%";
            content = {
              type = "luks";
              name = "installed-root";
              passwordFile = "/disk-key.txt";
              settings.allowDiscards = allowDiscards;
              extraFormatArgs = ["--pbkdf" "pbkdf2" "--iter-time" "1"];
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
in {
  inherit system;
}

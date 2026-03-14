top: moduleArgs @ {
  config,
  options,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
in {
  options.idr.preset.base = {
  };

  config = lib.mkIf cfg.base.enable (lib.mkMerge [
    # boot
    (lib.mkIf (!config.boot.isContainer) {
      assertions = [
        {
          assertion = options ? disko;
          message = "disko module must be imported.";
        }
      ];

      boot.zfs.devNodes = lib.mkOverride 51 "/dev/mapper";
      boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;
      boot.loader.grub = {
        enable = lib.mkDefault (options ? disko && (builtins.length (lib.attrNames config.disko.devices.disk)) > 0);
        configurationLimit = lib.mkDefault 20;
        efiSupport = lib.mkDefault true;
        useOSProber = lib.mkDefault false;
        efiInstallAsRemovable = lib.mkDefault true;
        splashImage = null;
        mirroredBoots =
          lib.mkOverride 51
          (lib.optionals (options ? disko) (lib.flatten
            (lib.mapAttrsToList (name: disk: let
              partitions = lib.attrValues disk.content.partitions;
              efi_partition = lib.findFirst (p: lib.elem (lib.toUpper p.type) ["EF00" "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"]) null partitions;
            in
              lib.optional
              (disk.type
                == "disk"
                && disk ? content.type
                && disk.content.type == "gpt"
                && efi_partition != null
                && (efi_partition.content.mountpoint or null) != null)
              {
                devices = (lib.optional (lib.any (p: lib.elem (lib.toUpper p.type) ["EF02" "21686148-6449-6E6F-744E-656564454649"]) partitions) disk.device) ++ ["nodev"];
                path = efi_partition.content.mountpoint;
                efiSysMountPoint = efi_partition.content.mountpoint;
              })
            config.disko.devices.disk)));
      };
    })
  ]);
}

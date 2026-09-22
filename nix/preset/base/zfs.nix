top: moduleArgs @ {
  config,
  options,
  pkgs,
  lib,
  utils,
  ...
}: let
  cfg = config.idr.preset;
  pools = config.disko.devices.zpool or {};
in {
  options.idr.preset.base = {
    importZpoolsBeforeLuks = lib.mkOption {
      description = ''
        Import Disko ZFS pools after cryptsetup.target, once their LUKS devices
        have been unlocked.
      '';
      type = lib.types.bool;
      default = true;
    };
  };

  config = lib.mkIf cfg.base.enable (lib.mkMerge [
    # zfs
    (lib.mkIf (!config.boot.isContainer) {
      # disable io scheduler for disks where we have zfs filesystem as zfs has it's own scheduler.
      boot.initrd.services.udev.rules = ''
        KERNEL=="vd[a-z]*[0-9]*|sd[a-z]*[0-9]*|mmcblk[0-9]*p[0-9]*|nvme[0-9]*n[0-9]*p[0-9]*", ENV{ID_FS_TYPE}=="zfs_member", ATTR{../queue/scheduler}="none"
      '';

      services.zfs.autoScrub.enable = lib.mkDefault true;
      boot.zfs.forceImportRoot = lib.mkDefault false;
    })

    (lib.optionalAttrs (options ? disko.zfs) (lib.mkIf (!config.boot.isContainer) {
      disko.zfs = {
        enable = lib.mkDefault (pools != {});
        # disko-zfs only reconciles filesystems, not ZVOLs.
        settings.ignoredDatasets = lib.concatLists (lib.mapAttrsToList (pool: poolConfig:
          lib.mapAttrsToList (name: _: "${pool}/${name}")
          (lib.filterAttrs (_: dataset: dataset.type == "zfs_volume") poolConfig.datasets))
        pools);
      };
      systemd.services.disko-zfs = lib.mkIf config.disko.zfs.enable {
        # Mounts added by a deployment must wait for their datasets.
        before =
          lib.mapAttrsToList (mountpoint: _: "${utils.escapeSystemdPath mountpoint}.mount")
          (lib.filterAttrs (_: fs: fs.fsType == "zfs" && !utils.fsNeededForBoot fs) config.fileSystems);
      };
    }))

    # ZFS import must be after cryptsetup, as we use luks encrypted partitions.
    (lib.mkIf (!config.boot.isContainer && cfg.base.importZpoolsBeforeLuks) {
      boot.initrd.systemd.services =
        lib.concatMapAttrs (zpool: cfg: {
          "zfs-import-${zpool}".after = ["cryptsetup.target"];
        })
        pools;
    })
  ]);
}

top: {
  config,
  lib,
  pkgs,
  ...
}: {
  imports =
    (with top.self.modules.nixos; [disko preset sops])
    ++ [
      (lib.modules.importApply ../../../backup/nixos-module.nix top)
    ];
  _module.args.inputs = top.inputs;

  virtualisation = {
    cores = 2;
    memorySize = 2048;
    emptyDiskImages = [1024];
  };
  networking.useDHCP = false;
  services.timesyncd.enable = false;
  boot.supportedFilesystems = ["zfs"];
  boot.loader.grub.enable = false;
  boot.initrd.network.ssh.enable = false;
  users.allowNoPasswordLogin = true;
  virtualisation.podman.enable = false;
  services.fail2ban.enable = false;
  idr.preset.base.inputs = {inherit (top) self;};

  # The test harness owns the root disk. Disko prepares only this disposable
  # data disk, and its normal filesystem configuration must not mount it early.
  disko = {
    enableConfig = false;
    rootMountPoint = "/";
    devices.disk.data = {
      type = "disk";
      device = "/dev/vdb";
      content = {
        type = "gpt";
        partitions.zfs = {
          size = "100%";
          content = {
            type = "zfs";
            pool = "p1";
          };
        };
      };
    };
    devices.zpool.p1 = {
      type = "zpool";
      rootFsOptions = {
        mountpoint = "none";
        canmount = "off";
      };
      datasets = {};
    };
  };
  systemd.services.test-data-disk = {
    wantedBy = ["multi-user.target"];
    before = ["sanoid.service" "idr-backup-access.service" "idr-backup-prepare.service"];
    after = ["dev-vdb.device" "systemd-modules-load.service"];
    requires = ["dev-vdb.device"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = config.system.build.formatScript;
    };
  };
  # Timers remain installed, but a distant calendar keeps assertions independent
  # of wall-clock boundaries. Tests invoke the documented systemd services.
  services.sanoid.interval = "2099-01-01 00:00:00";
  environment.systemPackages = [pkgs.sanoid];
}

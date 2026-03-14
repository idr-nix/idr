top: {
  config,
  lib,
  ...
}: let
  services = import ./qemu/guest-services.nix {
    inherit lib;
    machineId = config.idr.preset.base.id;
    networkPrefix = config.idr.qemu.networkPrefix;
  };
in {
  imports = [../../qemu-network/options.nix];

  config = lib.mkIf (config.idr.preset.base.enable && !config.boot.isContainer && config.systemd.network.enable) {
    boot.initrd.availableKernelModules = ["qemu_fw_cfg" "virtio_pci" "virtio_net"];

    systemd.services.idr-qemu-network = services.network;
    systemd.services.idr-qemu-ssh = lib.mkIf config.services.openssh.enable services.ssh;
    services.openssh.authorizedKeysFiles = lib.mkIf config.services.openssh.enable (
      lib.mkAfter ["/run/idr-qemu-ssh/%u"]
    );
    boot.initrd.systemd = lib.mkIf config.boot.initrd.systemd.enable {
      network.enable = true;
      services.idr-qemu-network = services.network;
      services.sshd = lib.mkIf config.boot.initrd.network.ssh.enable {
        unitConfig = {
          ConditionCredential = ["|!idr.workspace-id" "|!idr.qemu-ssh-key"];
          ConditionPathExistsGlob = "|/run/systemd/ask-password/ask.*";
        };
        serviceConfig.ImportCredential = ["idr.workspace-id" "idr.qemu-ssh-key"];
        preStart = lib.mkAfter ''
          if [[ -f "$CREDENTIALS_DIRECTORY/idr.workspace-id" && -f "$CREDENTIALS_DIRECTORY/idr.qemu-ssh-key" ]]; then
            printf '\nrestrict %s\n' "$(< "$CREDENTIALS_DIRECTORY/idr.qemu-ssh-key")" >> /etc/ssh/authorized_keys.d/root
          fi
        '';
      };
      paths.idr-qemu-unlock = lib.mkIf config.boot.initrd.network.ssh.enable {
        description = "Start local QEMU SSH when a disk needs unlocking";
        wantedBy = ["initrd.target"];
        unitConfig = {
          DefaultDependencies = false;
          ConditionCredential = ["idr.workspace-id" "idr.qemu-ssh-key"];
        };
        pathConfig = {
          PathExistsGlob = "/run/systemd/ask-password/ask.*";
          Unit = "sshd.service";
        };
      };
    };
  };
}

{
  pkgs,
  nixosImages,
  machineId,
  networkPrefix,
  qemuUdevRules,
  sshPorts,
}: let
  services = import ./guest-services.nix {
    inherit (pkgs) lib;
    inherit machineId networkPrefix;
  };
  installer =
    (pkgs.nixos [
      nixosImages.nixosModules.image-installer
      ({lib, ...}: {
        boot.initrd.availableKernelModules = ["qemu_fw_cfg" "virtio_pci" "virtio_net"];
        networking.networkmanager.enable = lib.mkForce false;
        systemd.services.idr-qemu-network = services.network;
        systemd.services.idr-qemu-ssh = services.ssh;
        services.openssh.ports = sshPorts;
        services.openssh.authorizedKeysFiles = lib.mkAfter ["/run/idr-qemu-ssh/%u"];
        services.udev.extraRules = qemuUdevRules;
      })
    ])
  .config.system.build.isoImage;
in
  installer.overrideAttrs (previous: {
    passthru =
      (previous.passthru or {})
      // {
        offlineDependencies = [
          # The ISO discards references; retain its inputs for offline rebuilds.
          (installer.overrideAttrs {unsafeDiscardReferences = {};}).inputDerivation
          # EFI payloads embed these tools without retaining their store references.
          pkgs.refind
          pkgs.libfaketime
        ];
      };
  })

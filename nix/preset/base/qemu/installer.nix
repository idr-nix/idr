{
  pkgs,
  nixosImages,
}: let
  services = import ./guest-services.nix {
    inherit (pkgs) lib;
  };
  # The upstream network-status UI and root-password generator have no enable
  # options. Remove their definitions without forcing their package values;
  # installer tools supplied by the imported modules are retained.
  imageInstaller = args @ {
    lib,
    pkgs,
    modulesPath,
    ...
  }: let
    upstream = import nixosImages.nixosModules.image-installer args;
  in
    upstream
    // {
      environment = builtins.removeAttrs upstream.environment ["systemPackages"];
      programs =
        upstream.programs
        // {
          bash = builtins.removeAttrs upstream.programs.bash ["interactiveShellInit"];
        };
      system =
        upstream.system
        // {
          activationScripts = builtins.removeAttrs upstream.system.activationScripts ["root-password"];
        };
    };
  installer =
    (pkgs.nixos [
      imageInstaller
      ({lib, ...}: {
        # VM networking and SSH keys come from the QEMU credentials.
        tor-ssh.enable = lib.mkForce false;
        networking.wireless.iwd.enable = lib.mkForce false;
        boot.initrd.availableKernelModules = ["qemu_fw_cfg" "virtio_pci" "virtio_net"];
        networking.networkmanager.enable = lib.mkForce false;
        services.openssh.enable = true;
        systemd.services.idr-qemu-network = services.network;
        systemd.services.idr-qemu-ssh = services.ssh;
        # Configure ports at boot, without baking a machine's settings into the ISO.
        services.openssh.ports = lib.mkForce [];
        services.openssh.extraConfig = "Include /run/idr-qemu-installer/sshd.conf";
        services.openssh.authorizedKeysFiles = lib.mkAfter ["/run/idr-qemu-ssh/%u"];
        systemd.services.idr-qemu-installer = {
          description = "Configure the shared IDR installer for this VM";
          before = ["sshd.service"];
          after = ["systemd-udev-trigger.service"];
          unitConfig.ConditionCredential = "idr.installer-config";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ImportCredential = ["idr.installer-config"];
            RuntimeDirectory = "idr-qemu-installer";
          };
          path = [pkgs.jq pkgs.systemd];
          script = ''
            config="$CREDENTIALS_DIRECTORY/idr.installer-config"
            jq -r '(.sshPorts | if length == 0 then [22] else . end)[] | "Port \(.)"' "$config" > /run/idr-qemu-installer/sshd.conf
            mkdir -p /run/udev/rules.d
            jq -r '.qemuUdevRules' "$config" > /run/udev/rules.d/99-idr-qemu-disks.rules
            udevadm control --reload
            udevadm trigger --subsystem-match=block --action=add
            udevadm settle
          '';
        };
        systemd.services.sshd = {
          requires = ["idr-qemu-installer.service"];
          after = ["idr-qemu-installer.service"];
        };
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

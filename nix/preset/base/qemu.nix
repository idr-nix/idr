top: moduleArgs @ {
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
  installer = import ./qemu/installer.nix {
    inherit pkgs;
    nixosImages = top.inputs.nixos-images;
    machineId = cfg.base.id;
    networkPrefix = config.idr.qemu.networkPrefix;
    qemuUdevRules = config.system.build.idr.meta.disko.qemuUdevRules;
    sshPorts = config.services.openssh.ports;
  };
in {
  imports = top.idr-lib.importApplyAll top [./qemu-network.nix];

  options.idr.meta.preset.base.qemu = {
    memorySize = lib.mkOption {
      description = ''
        Default RAM (in MiB) for config.system.build.idrQemu. QEMU's built-in
        default (128 MiB) is far too little to boot a NixOS system. Overridable
        at runtime by passing another `-m` via IDR_QEMU_EXTRA_OPTIONS_JSON.
      '';
      type = lib.types.ints.positive;
      default = 4096;
    };

    firmware = lib.mkOption {
      description = ''
        Firmware passed to QEMU with `-bios`. Set to `null` to use QEMU's
        default firmware.
      '';
      type = with lib.types; nullOr str;
      default = null;
      defaultText = lib.literalExpression ''"''${pkgs.OVMF.fd}/FV/OVMF.fd"'';
    };

    installerIso = lib.mkOption {
      description = "Installer ISO used when the local VM has no bootable disk.";
      type = lib.types.path;
      default = "${installer}/iso/nixos-installer-${pkgs.stdenv.hostPlatform.system}.iso";
      defaultText = "nixos-images installer with local QEMU networking";
    };

    graphics = lib.mkOption {
      description = ''
        Whether config.system.build.idrQemu opens QEMU's GTK graphical
        display. When disabled, `-display none` is passed to QEMU.
      '';
      type = lib.types.bool;
      default = false;
    };

    vnc.enable = lib.mkOption {
      description = ''
        Whether config.system.build.idrQemu exposes the QEMU display through
        a Unix-domain VNC socket under PRJ_DATA_DIR.
      '';
      type = lib.types.bool;
      default = false;
    };

    audio = {
      enable = lib.mkOption {
        description = ''
          Whether to add the configured audio options when graphics or VNC
          is enabled.
        '';
        type = lib.types.bool;
        default = true;
      };

      options = lib.mkOption {
        description = ''
          QEMU options used for audio. Replace this list to use another audio
          device or backend.
        '';
        type = with lib.types; listOf str;
        default = [
          "-audio"
          "driver=none"
          "-device"
          "intel-hda"
          "-device"
          "hda-duplex"
        ];
      };
    };

    clipboard = {
      enable = lib.mkOption {
        description = ''
          Whether to add the configured clipboard options when graphics or
          VNC is enabled. The guest Spice vdagent service is enabled by default
          in that case.
        '';
        type = lib.types.bool;
        default = true;
      };

      options = lib.mkOption {
        description = ''
          QEMU options used for clipboard synchronization. Replace this list
          to use another clipboard device.
        '';
        type = with lib.types; listOf str;
        default = [
          "-chardev"
          "qemu-vdagent,id=idr-vdagent,clipboard=on,mouse=off"
          "-device"
          "virtio-serial-pci,id=idr-virtio-serial"
          "-device"
          "virtserialport,bus=idr-virtio-serial.0,chardev=idr-vdagent,name=com.redhat.spice.0"
        ];
      };
    };

    video = {
      enable = lib.mkOption {
        description = ''
          Whether to add the configured video options when graphics or VNC
          is enabled.
        '';
        type = lib.types.bool;
        default = true;
      };

      options = lib.mkOption {
        description = ''
          QEMU options used for video. Replace this list to use another video
          device.
        '';
        type = with lib.types; listOf str;
        default = [
          "-vga"
          "virtio"
        ];
      };
    };

    options = lib.mkOption {
      description = ''
        Additional QEMU options used by config.system.build.idrQemu.
      '';
      type = with lib.types; listOf str;
      default = [];
    };
  };

  config = lib.mkIf (cfg.base.enable && !config.boot.isContainer && config.disko.devices.disk or {} != {}) (let
    meta = config.system.build.idr.meta.disko;
    qemuCfg = config.idr.meta.preset.base.qemu;
    displayEnabled = qemuCfg.graphics || qemuCfg.vnc.enable;
    diskBuses = map (disk: disk.qemu.bus) (builtins.attrValues meta.disks);
    qemuInitrdModules = lib.unique (
      lib.optionals (builtins.elem "ata" diskBuses) ["ata_piix" "sd_mod"]
      ++ lib.optionals (builtins.elem "nvme" diskBuses) ["nvme"]
      ++ lib.optionals (builtins.elem "scsi" diskBuses) ["sd_mod" "virtio_pci" "virtio_scsi"]
      ++ lib.optionals (builtins.elem "virtio" diskBuses) ["virtio_blk" "virtio_pci"]
    );
    qemuUdevRules = meta.qemuUdevRules;
    qemuOptions =
      [
        "-m"
        (toString qemuCfg.memorySize)
        "-drive"
        "file=${qemuCfg.installerIso},if=none,id=idr-installer,media=cdrom,readonly=on"
        "-device"
        "virtio-scsi-pci,id=idr-installer-scsi"
        "-device"
        "scsi-cd,bus=idr-installer-scsi.0,drive=idr-installer,bootindex=${toString (builtins.length diskBuses + 1)}"
      ]
      ++ (
        if qemuCfg.graphics
        then ["-display" "gtk"]
        else ["-display" "none"]
      )
      ++ lib.optionals (qemuCfg.firmware != null) [
        "-bios"
        qemuCfg.firmware
      ]
      ++ lib.optionals displayEnabled (
        lib.optionals qemuCfg.video.enable qemuCfg.video.options
        ++ lib.optionals qemuCfg.audio.enable qemuCfg.audio.options
        ++ lib.optionals qemuCfg.clipboard.enable qemuCfg.clipboard.options
      )
      ++ meta.qemuOptions
      ++ qemuCfg.options;
    scriptsDir = ../../scripts;
    sopsConfig = cfg.base.inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.idr-sops-config;
    sopsFilename = lib.removePrefix "${cfg.base.inputs.self}/" (toString cfg.base.defaultSopsFile);
    # QEMU finds this packaged ACL beside the copied helper, without using host configuration.
    bridgeHelper = pkgs.runCommand "idr-qemu-bridge-helper" {} ''
      install -Dm755 ${pkgs.qemu}/libexec/qemu-bridge-helper $out/libexec/qemu-bridge-helper
      mkdir -p $out/libexec/qemu-bundle/etc/qemu
      echo 'allow idr0' > $out/libexec/qemu-bundle/etc/qemu/bridge.conf
    '';
    networkAskpass = pkgs.writers.writeNuBin "idr-qemu-network-askpass" ''
      def main [prompt: string] {
        exec ${lib.getExe pkgs.rofi} -dmenu -password -input /dev/null -format s -kb-toggle-case-sensitivity "" -p $prompt
      }
    '';
    networkBootstrap = pkgs.writers.writeNuBin "idr-qemu-network-bootstrap" ''
      def main [--fd: int = 0, --br: string, --use-vnet] {
        if (^${pkgs.coreutils}/bin/id -u | into int) != 0 {
          print --stderr "Warning: using sudo to set up the idr0 network."
          $env.SUDO_ASKPASS = $env.SUDO_ASKPASS? | default --empty "${lib.getExe networkAskpass}"
          # Preserve the helper socket and unblock QEMU's SIGCHLD mask so sudo can reap its child.
          exec ${pkgs.socat}/bin/socat $"FD:($fd)" $"EXEC:${pkgs.coreutils}/bin/env --default-signal=CHLD sudo --askpass -- ($nu.current-exe) -n --no-std-lib --no-history ($env.CURRENT_FILE) --fd=0,nofork"
        }

        # Another VM may have already created the bridge.
        ^${pkgs.iproute2}/bin/ip link add name idr0 type bridge | complete | ignore
        ^${pkgs.iproute2}/bin/ip -6 address replace "${config.idr.qemu.networkPrefix}::1/48" dev idr0
        ^${pkgs.iproute2}/bin/ip link set dev idr0 up
        ^${pkgs.iproute2}/bin/ip -6 route replace "${config.idr.qemu.networkPrefix}::/48" dev idr0 metric 256
        exec ${bridgeHelper}/libexec/qemu-bridge-helper --use-vnet --br=idr0 $"--fd=($fd)"
      }
    '';
  in {
    # Disko substitutes virtio disks while building images; keep the machine's original identities.
    disko.imageBuilder.extraConfig.system.build.idr = lib.mkForce config.system.build.idr;

    boot.initrd.availableKernelModules = qemuInitrdModules;
    boot.initrd.services.udev.rules = qemuUdevRules;

    services.udev.extraRules = qemuUdevRules;

    services.spice-vdagentd.enable =
      lib.mkIf (displayEnabled && qemuCfg.clipboard.enable)
      (lib.mkDefault true);

    systemd.services.spice-vdagentd.unitConfig.ConditionPathExists =
      lib.mkIf (displayEnabled && qemuCfg.clipboard.enable)
      (lib.mkDefault "/dev/virtio-ports/com.redhat.spice.0");

    idr.meta.preset.base.qemu.firmware = lib.mkDefault "${pkgs.OVMF.fd}/FV/OVMF.fd";

    system.build.idrQemu = pkgs.writeShellApplication {
      name = "idrQemu";
      passthru = {inherit installer;};
      runtimeInputs = with pkgs; [
        coreutils
        gitMinimal
        iproute2
        nix
        (nushell.override {
          # Stop background unlock commands when the runner receives SIGTERM.
          additionalFeatures = features: features ++ ["ctrlc/termination"];
        })
        openssl
        openssh
        qemu
        sops
        util-linuxMinimal
      ];
      text = ''
        export IDR_QEMU_PROJECT_ROOT="''${PRJ_ROOT:-}"
        export PRJ_ROOT=${lib.escapeShellArg meta.self}
        export IDR_QEMU_MACHINE=${lib.escapeShellArg config.networking.hostName}
        export IDR_QEMU_MACHINE_ID=${lib.escapeShellArg cfg.base.id}
        export IDR_QEMU_NETWORK_PREFIX=${lib.escapeShellArg config.idr.qemu.networkPrefix}
        export IDR_QEMU_NETWORK_BOOTSTRAP=${lib.escapeShellArg (lib.getExe networkBootstrap)}
        export IDR_QEMU_UNLOCK_PORT=${toString config.boot.initrd.network.ssh.port}
        ${lib.optionalString (cfg.base.defaultSopsFile != null) ''
          export IDR_QEMU_SOPS_CONFIG=${lib.escapeShellArg sopsConfig}
          export IDR_QEMU_SOPS_FILENAME=${lib.escapeShellArg sopsFilename}
        ''}
        export IDR_QEMU_OPTIONS_JSON=${lib.escapeShellArg (builtins.toJSON qemuOptions)}
        export IDR_QEMU_EXTRA_OPTIONS_JSON="''${IDR_QEMU_EXTRA_OPTIONS_JSON:-[]}"
        export IDR_QEMU_VNC_ENABLED=${lib.escapeShellArg (builtins.toJSON qemuCfg.vnc.enable)}
        export IDR_MK_IMAGES_SCRIPT=${lib.escapeShellArg "${scriptsDir}/idr-mk-images.nu"}

        exec nu -n --no-std-lib --no-history ${scriptsDir}/idr-qemu.nu "$@"
      '';
      meta = {
        mainProgram = "idrQemu";
      };
    };
  });
}

top: moduleArgs @ {
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
  # Resolve through IDR, not the client project's package set or machine config.
  installer = top.inputs.idr.packages.${pkgs.stdenv.hostPlatform.system}.idr-qemu-installer;
  builders = top.inputs.idr.legacyPackages.${pkgs.stdenv.hostPlatform.system}.idrQemuBuilders;
in {
  imports = top.idr-lib.importApplyAll top [./qemu-network.nix];

  options.idr.meta.preset.base.qemu = {
    runtimePackage = lib.mkOption {
      description = "Host tools and helpers used to run local QEMU VMs.";
      type = lib.types.package;
      default = top.inputs.idr.packages.${pkgs.stdenv.hostPlatform.system}.idr-qemu-runtime;
      defaultText = "IDR's shared QEMU runtime";
    };
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
      defaultText = "IDR's shared OVMF firmware";
    };

    installerIso = lib.mkOption {
      description = "Installer ISO used when the local VM has no bootable disk.";
      type = lib.types.path;
      default = "${installer}/iso/nixos-installer-${pkgs.stdenv.hostPlatform.system}.iso";
      defaultText = "IDR's shared QEMU installer ISO";
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
    installerConfig = builders.writeText "idr-qemu-installer-config.json" (builtins.toJSON {
      inherit qemuUdevRules;
      sshPorts = config.services.openssh.ports;
    });
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
        "-fw_cfg"
        "name=opt/io.systemd.credentials/idr.installer-config,file=${installerConfig}"
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
    sopsConfig = cfg.base.inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.idr-sops-config;
    sopsFilename = lib.removePrefix "${cfg.base.inputs.self}/" (toString cfg.base.defaultSopsFile);
    runtimeEnvironment =
      {
        IDR_QEMU_MACHINE = config.networking.hostName;
        IDR_QEMU_MACHINE_ID = cfg.base.id;
        IDR_QEMU_NETWORK_PREFIX = config.idr.qemu.networkPrefix;
        IDR_QEMU_UNLOCK_PORT = toString config.boot.initrd.network.ssh.port;
        IDR_QEMU_OPTIONS_JSON = builtins.toJSON qemuOptions;
        IDR_QEMU_VNC_ENABLED = builtins.toJSON qemuCfg.vnc.enable;
      }
      // lib.optionalAttrs (cfg.base.defaultSopsFile != null) {
        IDR_QEMU_SOPS_CONFIG = toString sopsConfig;
        IDR_QEMU_SOPS_FILENAME = sopsFilename;
      };
    runtimeCommand = ''
      # Process Compose expands braced variables before reading its settings.
      # Keep defaults explicit so JSON-valued variables reach the shell intact.
      if [[ ! -v PRJ_ROOT ]]; then
        PRJ_ROOT=""
      fi
      export IDR_QEMU_PROJECT_ROOT="$PRJ_ROOT"
      export PRJ_ROOT=${lib.escapeShellArg meta.self}
      if [[ ! -v IDR_QEMU_EXTRA_OPTIONS_JSON || -z "$IDR_QEMU_EXTRA_OPTIONS_JSON" ]]; then
        export IDR_QEMU_EXTRA_OPTIONS_JSON="[]"
      fi
      exec ${lib.getExe qemuCfg.runtimePackage} "$@"
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

    idr.meta.preset.base.qemu.firmware = lib.mkDefault "${top.inputs.idr.packages.${pkgs.stdenv.hostPlatform.system}.idr-qemu-firmware}/FV/OVMF.fd";

    system.build.idrQemu = builders.writeShellApplication {
      name = "idrQemu";
      passthru = {
        inherit installer;
        runtime = qemuCfg.runtimePackage;
        # Embed machine data in Process Compose's config without depending on
        # the standalone wrapper, whose path changes with the project snapshot.
        processCompose = {
          command = runtimeCommand;
          environment = lib.mapAttrsToList (name: value: "${name}=${value}") runtimeEnvironment;
        };
      };
      text =
        lib.concatMapStringsSep "\n"
        (name: "export ${name}=${lib.escapeShellArg runtimeEnvironment.${name}}")
        (builtins.attrNames runtimeEnvironment)
        + "\n"
        + runtimeCommand;
      meta = {
        mainProgram = "idrQemu";
      };
    };
  });
}

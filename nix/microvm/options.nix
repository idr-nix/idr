{
  lib,
  pkgs,
  inputs,
  hostConfig,
}: {
  name,
  config,
  ...
}: let
  inherit (lib) mkOption types;
  vmName = name;
  hex = builtins.hashString "sha256" "idr/microvm/${name}";
  positiveOrHost = types.either types.ints.positive (types.enum ["host"]);
  positiveOrAuto = types.either types.ints.positive (types.enum ["auto"]);
  absolutePath = types.strMatching "/[^\n\r]*";
  pciAddress = types.strMatching "[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\\.[0-7]";
in {
  options = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable this Cloud Hypervisor VM.";
    };
    machine = mkOption {
      type = types.raw;
      description = "Declared IDR NixOS machine used for initial installation and subsequent guest deployments.";
    };
    autostart = mkOption {
      type = types.bool;
      default = true;
      description = "Start the VM when the host boots.";
    };
    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ./cloud-hypervisor.nix {src = inputs.cloud-hypervisor-src;};
      defaultText = lib.literalExpression "the locked Cloud Hypervisor source with native balloon statistics";
      description = "Cloud Hypervisor package. The default includes native balloon-stats for inspection.";
    };
    firmware = mkOption {
      type = types.path;
      default = pkgs.OVMF-cloud-hypervisor.firmware;
      defaultText = lib.literalExpression "pkgs.OVMF-cloud-hypervisor.firmware";
      description = "Cloud Hypervisor UEFI firmware file.";
    };
    vcpu = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "Number of boot vCPUs.";
    };
    shutdownTimeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 120;
      description = "Time allowed for ACPI shutdown before systemd terminates the VM.";
    };
    logLevel = mkOption {
      type = types.enum ["warn" "info" "debug" "trace"];
      default = "warn";
      description = "Cloud Hypervisor diagnostic verbosity in the VM service journal.";
    };
    console = mkOption {
      type = types.enum ["socket" "journal" "both"];
      default = "journal";
      description = ''
        Send the guest console to its private console.sock for interactive access,
        or to the VM service journal for boot diagnostics. Both keeps the serial
        console in the journal and exposes a separate virtio terminal on the socket.
      '';
    };
    memory = {
      hostPressure.enable = mkOption {
        type = types.bool;
        default = config.memory.enable;
        description = "Include this VM in Hypeman's shared host-pressure balloon policy.";
      };
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable virtio-balloon and free-page reporting.";
      };
      maximumMiB = mkOption {
        type = positiveOrHost;
        default = "host";
        description = "Flat RAM ceiling in MiB, or the target host's usable RAM measured at VM startup. RAM is backed lazily.";
      };
      minimumMiB = mkOption {
        type = positiveOrAuto;
        default = "auto";
        description = "Minimum initial boot budget and required controller floor. Auto accounts for page metadata and boot headroom. Hypeman's global protected floor must cover this value; it is not a resident-memory guarantee.";
      };
      initialMiB = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Initial guest memory budget; null starts with an empty balloon. Host backing still grows on demand.";
      };
    };
    disks = mkOption {
      type = types.attrsOf (types.submodule ({
        name,
        config,
        ...
      }: let
        diskName = name;
        disk = config;
      in {
        options = {
          path = mkOption {
            type = absolutePath;
            default = "/dev/zvol/${disk.dataset}";
            defaultText = lib.literalExpression ''"/dev/zvol/''${config.dataset}"'';
            example = "/var/lib/microvm-disks/worker.qcow2";
            description = ''
              Host block device or image file attached as
              /dev/disk/by-id/virtio-idr-<disk name> in the guest. The microvm
              user needs read/write access and directory traversal permission.
            '';
          };
          format = mkOption {
            type = types.enum ["raw" "qcow2"];
            default = "raw";
            description = "Disk format. Use raw for block devices and raw images, or qcow2 for standalone QCOW2 images without backing files.";
          };
          direct = mkOption {
            type = types.bool;
            default = disk.provisioning == "zvol";
            defaultText = lib.literalExpression ''config.provisioning == "zvol"'';
            description = "Use direct I/O. Enabled by default for managed zvols; other storage uses buffered I/O for filesystem compatibility.";
          };
          pool = mkOption {
            type = types.strMatching "[A-Za-z][A-Za-z0-9_.-]*";
            default = "p1";
            description = "Existing host ZFS pool used for the default managed-zvol path.";
          };
          dataset = mkOption {
            type = types.strMatching "[A-Za-z][A-Za-z0-9_.-]*(/[A-Za-z0-9_.:-]+)+";
            default = "${disk.pool}/idr-microvm-${vmName}${lib.optionalString (diskName != "system") "-${diskName}"}";
            description = "Managed zvol name. Its parent dataset must already exist.";
          };
          sizeMiB = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Initial managed disk size. Null uses the corresponding Disko image size. Changing this does not resize an installed disk.";
          };
          compression = mkOption {
            type = types.enum ["off" "on" "lz4" "zstd"];
            default = "zstd";
            description = "Compression for a newly provisioned zvol.";
          };
          primarycache = mkOption {
            type = types.enum ["all" "metadata" "none"];
            default = "metadata";
            description = "ZFS ARC caching for a newly provisioned zvol.";
          };
          provisioning = mkOption {
            type = types.enum ["zvol" "image" "block" "none"];
            default =
              if disk.path == "/dev/zvol/${disk.dataset}"
              then "zvol"
              else if lib.hasPrefix "/dev/" disk.path
              then "block"
              else "image";
            defaultText = "zvol for the default ZFS path, block for other /dev paths, image otherwise";
            description = ''
              How to install the corresponding named guest Disko disk. zvol
              manages the configured ZFS volume; image creates or initializes
              an unused image; block initializes an unused device or partition;
              none attaches storage without installation. Existing partition
              tables or recognizable filesystem/RAID signatures are preserved.
              QCOW2 images are initialized only when their virtual contents
              are all zero. Guest updates are controlled by deployment.autoUpdate.
            '';
          };
        };
      }));
      default = {system = {};};
      description = ''
        Host storage attached to the guest. Names correspond to guest Disko
        disks, which define their layouts. Defaults to one managed system zvol;
        an explicit disk set replaces that default.
      '';
    };
    provisioning.buildMemoryMiB = mkOption {
      type = types.ints.positive;
      default = 4096;
      description = "RAM for the first-install Disko image builder VM.";
    };
    network = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable native virtio-net over a host-managed TAP interface.";
      };
      tapName = mkOption {
        type = types.strMatching "[a-zA-Z0-9_-]{1,15}";
        default = "tap-${builtins.substring 0 10 hex}";
        description = "Host TAP interface.";
      };
      ipv4Address = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        default = config.machine.config.idr.microvmGuest.network.ipv4Address;
        defaultText = lib.literalExpression "machine.config.idr.microvmGuest.network.ipv4Address";
        description = "Reserved guest IPv4 address. Set by idr-mk-machine in the guest configuration.";
      };
      ipv6Address = mkOption {
        type = types.str;
        readOnly = true;
        default =
          (import ./network-lib.nix {inherit lib;}).ipv6Address
          hostConfig.idr.microvm.network.ipv6Prefix
          hostConfig.networking.hostId
          config.machine.config.idr.preset.base.id;
        defaultText = "IPv6 prefix followed by the host ID and guest machine ID";
        description = "Reserved guest IPv6 address, enforced on its TAP interface.";
      };
      macAddress = mkOption {
        type = types.strMatching "[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}";
        default = "02:${lib.concatStringsSep ":" (lib.genList (i: builtins.substring (i * 2) 2 hex) 5)}";
        description = "Stable guest MAC address.";
      };
      queuePairs = mkOption {
        type = positiveOrAuto;
        default = "auto";
        description = "Virtio-net RX/TX queue pairs; auto uses one pair per vCPU, up to eight pairs.";
      };
    };
    pci = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Bind the listed PCI functions to VFIO and assign devices through virtio-IOMMU.";
      };
      devices = mkOption {
        type = types.listOf pciAddress;
        default = [];
        description = "Host PCI addresses assigned to the guest.";
      };
      bindOnlyDevices = mkOption {
        type = types.listOf pciAddress;
        default = [];
        description = "Companion functions bound to VFIO but not assigned, for IOMMU-group viability.";
      };
    };
    shares = mkOption {
      default = {};
      description = "Named virtiofs exports. Mount the corresponding tag in the guest machine configuration.";
      type = types.attrsOf (types.submodule {
        options = {
          source = mkOption {
            type = absolutePath;
            description = "Existing host directory, including any mounted datasets to expose.";
          };
          readOnly = mkOption {
            type = types.bool;
            default = false;
            description = "Reject guest writes to this export.";
          };
          cache = mkOption {
            type = types.enum ["auto" "never" "metadata" "always"];
            default = "auto";
            description = "Virtiofs guest cache policy.";
          };
        };
      });
    };
    deployment.restartOnHypervisorChange = mkOption {
      type = types.bool;
      default = false;
      description = "Restart the VM when its hypervisor package or runtime configuration changes.";
    };
    deployment.autoUpdate = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Deploy the declared guest system to running VMs during host activation.
        Host boot and VM starts do not deploy guest updates. Uses management SSH
        over a private Unix socket, independently of guest networking. Disabling
        this retains the host's per-VM SSH and manual deployment commands.
      '';
    };
    deployment.vsockCid = mkOption {
      type = types.ints.between 3 2147483647;
      default = 3 + lib.mod (lib.fromHexString (builtins.substring 0 8 hex)) 2147483644;
      description = "Stable guest VSOCK ID for the private deployment transport.";
    };
  };
}

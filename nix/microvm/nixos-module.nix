top: {
  config,
  lib,
  options,
  pkgs,
  utils,
  ...
}: let
  inherit (lib) mkIf optional optionals;
  inputs = top.inputs;
  sshHostKey = lib.findFirst (key: key.type == "ed25519") null config.services.openssh.hostKeys;
  sshHostKeyPath =
    if sshHostKey == null
    then null
    else sshHostKey.path;
  hostPublicKey = let
    sopsFile = config.idr.preset.base.defaultSopsFile or null;
  in
    if sopsFile == null
    then null
    else (lib.importJSON sopsFile).ssh_host_ed25519_key_pub_unencrypted or null;
  # Comments and authorized_keys options do not change the host key identity.
  keyMaterial = key: let
    fields = builtins.filter (field: field != "") (lib.splitString " " (lib.replaceStrings ["\t"] [" "] key));
    index = lib.lists.findFirstIndex (field: field == "ssh-ed25519") (builtins.length fields) fields;
  in
    lib.sublist index 2 fields;
  cfgs = lib.filterAttrs (_: vm: vm.enable) config.idr.microvm.vms;
  allDisks = lib.concatMap (vm: builtins.attrValues vm.disks) (builtins.attrValues cfgs);
  managedZvols = builtins.filter (disk: disk.provisioning == "zvol") allDisks;
  storageDatasets = map (disk: disk.dataset) managedZvols;
  storagePaths = map (disk: disk.path) allDisks;
  networkVMs = lib.filterAttrs (_: vm: vm.network.enable) cfgs;
  pciVMs = lib.filterAttrs (_: vm: vm.pci.enable) cfgs;
  pressureVMs = lib.filterAttrs (_: vm: vm.memory.hostPressure.enable) cfgs;
  managementVMs = lib.filterAttrs (_: vm: (vm.machine.config.idr.microvmGuest.enable or false) && (vm.machine.config.idr.microvmGuest.deployment.enable or false)) cfgs;
  pciAddresses = lib.concatMap (vm: vm.pci.devices ++ vm.pci.bindOnlyDevices) (builtins.attrValues pciVMs);
  unique = values: builtins.length values == builtins.length (lib.unique values);
  validName = name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}" name != null;
  validDiskName = name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]{0,15}" name != null;
  validShareName = name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]{0,35}" name != null;
  # RequiresMountsFor accepts quoted paths and expands specifiers, but does not
  # use ExecStart's environment-variable substitution rules.
  systemdPath = path: builtins.toJSON (lib.replaceStrings ["%"] ["%%"] path);

  instances =
    lib.mapAttrs (name: vm: let
      unitName = "idr-microvm-${name}";
      instanceName = "idr-${name}";
      serviceName = "microvm@${instanceName}";
      machine = vm.machine;
      guest = machine.config;
      guestDisks = guest.disko.devices.disk or {};
      # Runtime and provisioning share each disk's attachment and image identity.
      disks = lib.mapAttrs (diskName: disk:
        disk
        // {
          name = diskName;
          serial = "idr-${diskName}";
          imageName = guestDisks.${diskName}.imageName or null;
        })
      vm.disks;
      managedDisks = lib.filterAttrs (_: disk: disk.provisioning != "none") disks;
      needsInstallation = managedDisks != {};
      hasManagedZvol = lib.any (disk: disk.provisioning == "zvol") (builtins.attrValues disks);
      metadata = guest.system.build.idr.meta.disko or (throw "${unitName}: machine must be a declared IDR machine with Disko installation metadata.");
      needsHostKey = needsInstallation && (metadata.preFormatFiles != {} || metadata.postFormatFiles != {});
      hostSystem = pkgs.stdenv.hostPlatform.system;
      machineName = guest.networking.hostName;
      # IDR captures its own dependencies in top.inputs. The machine and its
      # image builder belong to the consuming project's flake instead.
      machineFlake = guest.idr.preset.base.inputs.self or (throw "${unitName}: machine must belong to an IDR project.");
      idrBuilder = machineFlake.legacyPackages.${hostSystem}.idrDiskoImagesScript.${machineName} or null;
      registeredMachine = machineFlake.nixosConfigurations.${machineName} or null;
      idrBuilderMatches =
        idrBuilder
        != null
        && registeredMachine != null
        && registeredMachine.config.system.build.toplevel == guest.system.build.toplevel;
      imageBuilder =
        if idrBuilderMatches
        then idrBuilder
        else throw "${unitName}: machine must match its project's nixosConfigurations.${machineName} and IDR image builder.";
      runtime = import ./runtime.nix {
        inherit lib pkgs unitName instanceName vm disks;
        bridgeName = config.idr.microvm.network.bridgeName;
        microvm = inputs.microvm;
      };
      provision =
        if needsInstallation
        then
          import ./provision.nix {
            inherit lib pkgs unitName machine imageBuilder metadata sshHostKeyPath vm disks;
            zfsPackage =
              if hasManagedZvol
              then config.boot.zfs.package
              else null;
          }
        else null;
      deployment =
        if runtime.managementEnabled
        then
          import ./deployment.nix {
            inherit lib pkgs inputs unitName instanceName vm machine sshHostKeyPath;
            inherit (runtime) vsockSocket;
            hostName = config.networking.hostName;
            vmName = name;
          }
        else null;
    in {
      inherit unitName instanceName serviceName machine runtime provision deployment disks guestDisks managedDisks needsHostKey needsInstallation hasManagedZvol;
    })
    cfgs;

  memoryManagement = import ./memory.nix {
    inherit lib pkgs;
    src = inputs.hypeman-src;
    settings = config.idr.microvm.memory;
    vms =
      lib.mapAttrs (name: _: {
        apiSocket = instances.${name}.runtime.apiSocket;
        memoryState = instances.${name}.runtime.memoryState;
      })
      pressureVMs;
  };

  pciOverride =
    lib.concatMapStringsSep "\n" (address: ''
      if [ -d /sys/bus/pci/devices/${lib.toLower address} ]; then
        echo vfio-pci > /sys/bus/pci/devices/${lib.toLower address}/driver_override
      fi
    '')
    pciAddresses;

  servicesFor = name: vm: let
    inherit (instances.${name}) unitName instanceName serviceName provision deployment needsHostKey runtime disks hasManagedZvol;
    unit = "${serviceName}.service";
    storageDevices = map (disk: "${utils.escapeSystemdPath disk.path}.device") (builtins.filter (disk: disk.provisioning != "zvol" && lib.hasPrefix "/dev/" disk.path) (builtins.attrValues disks));
    storageMounts = map (disk: systemdPath disk.path) (builtins.attrValues disks);
    installationDependencies = optional (provision != null) "${unitName}-install.service";
    booted = "${config.microvm.stateDir}/${instanceName}/booted";
    bootedCommand = command: {
      # A backend crash after a host deployment must keep using the running
      # VM's exports/devices, until its entire service group is restarted.
      unitConfig.ConditionPathExists = ["" "${booted}/bin/${command}"];
      serviceConfig.ExecStart = ["" "${booted}/bin/${command}"];
    };
    prepareRuntimeDirectory = ''
      # Secure the parent first, including when upgrading an existing VM.
      # The VMM then cannot replace private while root checks and creates it.
      ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g kvm /run/${unitName}
      if [ -L ${runtime.privateDirectory} ]; then
        echo "Refusing a symlink at ${runtime.privateDirectory}" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/install -d -m 0700 -o microvm -g kvm ${runtime.privateDirectory}
    '';
    # Only these drop-ins are changed. Existing microvm.nix VMs keep their
    # service defaults, runners and device setup.
    skipInLocalVM =
      lib.genAttrs [
        serviceName
        "microvm-tap-interfaces@${instanceName}"
        "microvm-macvtap-interfaces@${instanceName}"
        "microvm-pci-devices@${instanceName}"
        "microvm-virtiofsd@${instanceName}"
        "microvm-set-booted@${instanceName}"
      ] (service: {
        overrideStrategy = "asDropin";
        unitConfig = {
          ConditionCredential = "!idr.workspace-id";
          # PartOf handles explicit stops; this also cleans up after guest
          # shutdown or a VMM crash, before the next start selects its runner.
          StopWhenUnneeded = service != serviceName;
        };
      })
      // {
        "install-microvm-${instanceName}" = {
          unitConfig = {
            ConditionCredential = "!idr.workspace-id";
            RequiresMountsFor = [(systemdPath config.microvm.stateDir)];
          };
          # The state directory may have been removed since tmpfiles last ran.
          # Start somewhere that exists, recreate it with its declared ownership,
          # then enter it before upstream writes the current/toplevel links.
          serviceConfig.WorkingDirectory = lib.mkForce "/";
          script = lib.mkBefore ''
            ${prepareRuntimeDirectory}
            ${pkgs.systemd}/bin/systemd-tmpfiles --create --prefix=${lib.escapeShellArg config.microvm.stateDir} 10-microvm.conf
            test ! -L ${lib.escapeShellArg "${config.microvm.stateDir}/${instanceName}"}
            cd -- ${lib.escapeShellArg "${config.microvm.stateDir}/${instanceName}"}
          '';
        };
      };
  in
    lib.mkMerge [
      skipInLocalVM
      (lib.optionalAttrs (deployment != null) {
        "${unitName}-deploy" = deployment.service;
      })
      {
        ${serviceName} = bootedCommand "microvm-run";
        "microvm-tap-interfaces@${instanceName}" = bootedCommand "tap-up";
        "microvm-pci-devices@${instanceName}" = bootedCommand "pci-setup";
        "microvm-virtiofsd@${instanceName}" = bootedCommand "virtiofsd-run";
      }
      (lib.optionalAttrs (provision != null) {
        "${unitName}-install" = {
          description = "Install guest disks for ${name} once";
          after = storageDevices ++ optional hasManagedZvol "zfs.target" ++ optional needsHostKey "sshd-keygen.service";
          requires = storageDevices ++ optional hasManagedZvol "zfs.target" ++ optional needsHostKey "sshd-keygen.service";
          before = [unit];
          partOf = [unit];
          restartIfChanged = false;
          unitConfig = {
            ConditionCredential = "!idr.workspace-id";
            StopWhenUnneeded = true;
            RequiresMountsFor = storageMounts;
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StateDirectory = "${unitName}-install";
            StateDirectoryMode = "0700";
            UMask = "0077";
            ExecStart = lib.getExe provision;
            TimeoutStartSec = "infinity";
          };
        };
      })
      {
        ${serviceName} = {
          requires = ["install-microvm-${instanceName}.service"] ++ installationDependencies ++ storageDevices;
          after = ["install-microvm-${instanceName}.service"] ++ installationDependencies ++ storageDevices;
          restartIfChanged = vm.deployment.restartOnHypervisorChange;
          unitConfig.RequiresMountsFor = storageMounts;
          serviceConfig = {
            RuntimeDirectory = "${unitName}/private";
            RuntimeDirectoryMode = "0700";
            Group = "kvm";
            # Virtiofs sockets share this directory and may outlive a failed VMM.
            RuntimeDirectoryPreserve = "yes";
            UMask = "0007";
            Restart = "no";
            TimeoutStopSec = vm.shutdownTimeoutSeconds + 10;
            MemoryAccounting = true;
            StandardInput = lib.mkDefault "null";
            StandardOutput = lib.mkDefault "journal";
            StandardError = lib.mkDefault "journal";
            ExecStartPost = lib.optional runtime.managementEnabled "+${pkgs.writeShellScript "${unitName}-secure-deployment-socket" ''
              set -euo pipefail
              deadline=$((SECONDS + 30))
              until [ -S ${lib.escapeShellArg runtime.vsockSocket} ]; do
                if (( SECONDS >= deadline )); then
                  echo "Timed out waiting for the MicroVM deployment socket" >&2
                  exit 1
                fi
                ${pkgs.coreutils}/bin/sleep 0.1
              done
              ${pkgs.coreutils}/bin/chown --no-dereference root:root ${lib.escapeShellArg runtime.vsockSocket}
              ${pkgs.coreutils}/bin/chmod --no-dereference 0600 ${lib.escapeShellArg runtime.vsockSocket}
            ''}";
          };
        };
        "microvm-set-booted@${instanceName}".serviceConfig.User = "root";
        "microvm-tap-interfaces@${instanceName}" = {
          after = ["systemd-networkd.service"];
          wants = ["systemd-networkd.service"];
        };
        "microvm-pci-devices@${instanceName}".after = ["microvm-set-booted@${instanceName}.service"];
        "microvm-virtiofsd@${instanceName}" = {
          unitConfig.RequiresMountsFor = map (share: systemdPath share.source) (builtins.attrValues vm.shares);
          preStart = prepareRuntimeDirectory;
          serviceConfig = {
            RuntimeDirectory = "${unitName}-virtiofsd";
            RuntimeDirectoryMode = "0700";
            UMask = "0007";
          };
        };
      }
    ];
in {
  key = toString ./nixos-module.nix;

  imports = [
    inputs.microvm.nixosModules.host
    (lib.modules.importApply ./network.nix top)
  ];

  options.idr.microvm = {
    vms = lib.mkOption {
      description = "Named Cloud Hypervisor VMs with persistent guest-owned boot and storage.";
      type = lib.types.attrsOf (lib.types.submodule (import ./options.nix {
        inherit lib pkgs inputs;
        hostConfig = config;
      }));
      default = {};
    };
    memory = import ./memory-options.nix {inherit lib;};
  };

  config = lib.mkMerge [
    {microvm.host.enable = lib.mkDefault (config.microvm.vms != {});}
    (lib.optionalAttrs (options.environment ? persistence) {
      environment.persistence = mkIf (config.idr.preset.impermanence.enable or false) {
        ${config.idr.preset.impermanence.persistDir or "/persist"}.directories =
          lib.mapAttrsToList (name: _: {
            directory = instances.${name}.deployment.stateDirectory;
            user = "root";
            group = "root";
            mode = "0700";
          })
          managementVMs;
      };
    })
    (mkIf (cfgs != {}) {
      assertions =
        [
          {
            assertion = unique (storageDatasets ++ map (dataset: "${dataset}-installing") storageDatasets);
            message = "idr.microvm: managed disk dataset values and their -installing staging names must be unique across all VMs and disks.";
          }
          {
            assertion = unique (storagePaths ++ map (dataset: "/dev/zvol/${dataset}-installing") storageDatasets);
            message = "idr.microvm: disk paths must be unique and must not use a managed zvol staging path.";
          }
          {
            assertion = unique (map (vm: lib.toLower vm.network.macAddress) (builtins.attrValues networkVMs));
            message = "idr.microvm: guest MAC addresses must be unique.";
          }
          {
            assertion = unique (map lib.toLower pciAddresses);
            message = "idr.microvm: PCI functions may belong to only one VM.";
          }
          {
            assertion = unique (map (vm: vm.network.tapName) (builtins.attrValues networkVMs));
            message = "idr.microvm: TAP interface names must be unique.";
          }
          {
            assertion = unique (map (vm: vm.deployment.vsockCid) (builtins.attrValues managementVMs));
            message = "idr.microvm: management VSOCK IDs must be unique.";
          }
        ]
        ++ memoryManagement.assertions
        ++ lib.concatLists (lib.mapAttrsToList (name: vm: let
          inherit (instances.${name}) unitName machine runtime disks guestDisks needsHostKey needsInstallation;
        in
          [
            {
              assertion = validName name;
              message = "${unitName}: VM names must use at most 40 letters, digits, underscores or hyphens, starting with a letter or digit.";
            }
            {
              assertion = name == machine.config.networking.hostName;
              message = "${unitName}: the VM name must match the referenced MicroVM machine's networking.hostName.";
            }
            {
              assertion = !needsHostKey || (config.services.openssh.enable && sshHostKeyPath != null);
              message = "${unitName}: encrypted installation files require an enabled host SSH service with an Ed25519 host key.";
            }
            {
              assertion = !vm.deployment.autoUpdate || runtime.managementEnabled;
              message = "${unitName}: automatic guest updates require idr.microvmGuest.deployment.enable in the guest.";
            }
            {
              assertion = !runtime.managementEnabled || (sshHostKeyPath != null && machine.config.system.build.idr.meta.sshHostPublicKey != null);
              message = "${unitName}: management access requires a host Ed25519 private key and the guest's declared SSH host public key.";
            }
            {
              assertion = !vm.deployment.autoUpdate || (machine.config.idr.microvmGuest.deployment.authorizedKeys != [] && (hostPublicKey == null || lib.any (key: keyMaterial key == keyMaterial hostPublicKey) machine.config.idr.microvmGuest.deployment.authorizedKeys));
              message = "${unitName}: authorize this host's SSH key for guest deployment, normally through the guest's idr.preset.base.sopsRecipientMachines.";
            }
            {
              assertion = machine.pkgs.stdenv.hostPlatform.system == pkgs.stdenv.hostPlatform.system;
              message = "${unitName}: the guest architecture must match the host.";
            }
            {
              assertion = vm.console != "both" || pkgs.stdenv.hostPlatform.isx86 || pkgs.stdenv.hostPlatform.isAarch64;
              message = "${unitName}: console = both requires an x86 or AArch64 guest with separate serial and virtio consoles.";
            }
            {
              assertion = !needsInstallation || lib.all (diskName: builtins.hasAttr diskName disks) (builtins.attrNames guestDisks);
              message = "${unitName}: initial installation requires a host disks entry for every guest Disko disk.";
            }
            {
              assertion = !needsInstallation || (machine.config.disko.imageBuilder.imageFormat or "") == "raw";
              message = "${unitName}: initial installation requires Disko to generate a RAW installation image.";
            }
            {
              assertion = !needsInstallation || machine.config.boot.loader.systemd-boot.enable || (machine.config.boot.loader.grub.enable && machine.config.boot.loader.grub.efiSupport);
              message = "${unitName}: initial installation requires the guest to install a UEFI bootloader.";
            }
            {
              assertion = !vm.network.enable || vm.network.queuePairs == "auto" || vm.network.queuePairs <= vm.vcpu;
              message = "${unitName}: network.queuePairs cannot exceed vcpu.";
            }
            {
              assertion = !vm.pci.enable || vm.pci.devices != [];
              message = "${unitName}: PCI passthrough needs at least one assigned device.";
            }
            {
              assertion = !vm.pci.enable || (builtins.elem "virtio_iommu" machine.config.boot.initrd.kernelModules && lib.all (parameter: builtins.elem parameter machine.config.boot.kernelParams) ["iommu.passthrough=0" "iommu.strict=1"]);
              message = "${unitName}: PCI passthrough requires the guest's virtio_iommu initrd module and translated, strict DMA. Import microvm/guest.nix in the guest configuration.";
            }
            {
              assertion = lib.all validShareName (builtins.attrNames vm.shares);
              message = "${unitName}: share tags must use at most 36 letters, digits, underscores or hyphens, starting with a letter or digit.";
            }
            {
              assertion = vm.memory.enable || vm.memory.initialMiB == null;
              message = "${unitName}: memory.initialMiB requires memory.enable.";
            }
            {
              assertion = !vm.memory.hostPressure.enable || vm.memory.enable;
              message = "${unitName}: host pressure management requires memory.enable.";
            }
            {
              assertion = let
                policy = config.idr.microvm.memory;
                minimum =
                  if vm.memory.minimumMiB == "auto"
                  then lib.max 512 (builtins.div (vm.memory.maximumMiB + 63) 64 + 256)
                  else vm.memory.minimumMiB;
                floor = lib.max policy.protectedFloorMiB (builtins.div (vm.memory.maximumMiB * policy.protectedFloorPercent) 100);
              in
                !vm.memory.hostPressure.enable || vm.memory.maximumMiB == "host" || minimum <= floor;
              message = "${unitName}: Hypeman's global protectedFloorPercent/protectedFloorMiB must cover this VM's minimumMiB. The same check is repeated against running limits at startup.";
            }
            {
              assertion = vm.memory.maximumMiB == "host" || vm.memory.minimumMiB == "auto" || vm.memory.minimumMiB <= vm.memory.maximumMiB;
              message = "${unitName}: memory.minimumMiB cannot exceed maximumMiB.";
            }
            {
              assertion = vm.memory.initialMiB == null || vm.memory.maximumMiB == "host" || vm.memory.initialMiB <= vm.memory.maximumMiB;
              message = "${unitName}: memory.initialMiB cannot exceed maximumMiB.";
            }
            {
              assertion = vm.memory.initialMiB == null || vm.memory.minimumMiB == "auto" || vm.memory.initialMiB >= vm.memory.minimumMiB;
              message = "${unitName}: memory.initialMiB cannot be below minimumMiB.";
            }
          ]
          ++ lib.concatLists (lib.mapAttrsToList (diskName: disk: let
              description = "${unitName}.disks.${diskName}";
            in [
              {
                assertion = validDiskName diskName;
                message = "${unitName}: disk names must use at most 16 letters, digits, underscores or hyphens, starting with a letter or digit.";
              }
              {
                assertion = disk.provisioning == "none" || builtins.hasAttr diskName guestDisks;
                message = "${description}: installation requires a guest disko.devices.disk.${diskName} definition.";
              }
              {
                assertion = disk.provisioning == "none" || disk.imageName == null || builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*" disk.imageName != null;
                message = "${description}: the Disko imageName must be a safe file basename.";
              }
              {
                assertion = disk.provisioning != "zvol" || lib.all (part: !builtins.elem part ["" "." ".."]) (lib.splitString "/" disk.dataset);
                message = "${description}: dataset cannot contain empty, dot or dot-dot components.";
              }
              {
                assertion = lib.hasPrefix "/" disk.path && lib.all (part: !builtins.elem part ["" "." ".."]) (builtins.tail (lib.splitString "/" disk.path));
                message = "${description}: path must be an absolute, non-root path without empty, dot or dot-dot components.";
              }
              {
                assertion = disk.provisioning != "zvol" || (disk.path == "/dev/zvol/${disk.dataset}" && disk.format == "raw");
                message = "${description}: zvol provisioning requires raw storage at /dev/zvol/\${dataset}.";
              }
              {
                assertion = disk.provisioning != "image" || (disk.path != "/dev" && !lib.hasPrefix "/dev/" disk.path);
                message = "${description}: image provisioning requires a file path outside /dev.";
              }
              {
                assertion = disk.provisioning != "block" || lib.hasPrefix "/dev/" disk.path;
                message = "${description}: block provisioning requires a block device path under /dev.";
              }
              {
                assertion = !lib.hasPrefix "/dev/" disk.path || disk.format == "raw";
                message = "${description}: block devices require format = \"raw\".";
              }
            ])
            disks))
        cfgs);

      microvm.vms = lib.mapAttrs' (name: vm: let
        inherit (instances.${name}) instanceName runtime;
      in
        lib.nameValuePair instanceName {
          inherit (vm) autostart;
          restartIfChanged = vm.deployment.restartOnHypervisorChange;
          # The upstream host module consumes only these fields. Its deployment
          # trigger is the runner, independently of the persistent guest closure.
          evaluatedConfig.config = {
            microvm = {
              declaredRunner = runtime;
              # The host module uses these sources only for tmpfiles rules.
              # The runner retains the literal paths used by virtiofsd.
              shares = map (share:
                share // {source = lib.replaceStrings ["%"] ["%%"] share.source;})
              runtime.shares;
            };
            system.build.toplevel = runtime;
          };
        })
      cfgs;

      services.udev.extraRules =
        lib.concatMapStringsSep "\n" (disk: ''
          SUBSYSTEM=="block", ACTION=="add|change", SYMLINK=="zvol/${disk.dataset}", OWNER="microvm", GROUP="root", MODE="0600"
        '')
        managedZvols;
      boot.supportedFilesystems = optionals (managedZvols != []) ["zfs"];
      boot.zfs.extraPools = lib.unique (map (dataset: builtins.head (lib.splitString "/" dataset)) storageDatasets);
      boot.kernelModules = ["tun"] ++ optionals (pciVMs != {}) ["vfio" "vfio_iommu_type1" "vfio_pci"];
      boot.kernelParams = optionals (pciVMs != {} && pkgs.stdenv.hostPlatform.isx86) ["intel_iommu=on" "amd_iommu=on" "iommu=pt"];
      boot.extraModprobeConfig = lib.optionalString (pciVMs != {}) ''
        options vfio_iommu_type1 dma_entry_limit=33554432
      '';
      boot.initrd.availableKernelModules = optionals (pciVMs != {}) ["vfio" "vfio_iommu_type1" "vfio_pci"];
      boot.initrd.systemd.services.idr-microvm-pci = mkIf (config.boot.initrd.systemd.enable && pciVMs != {}) {
        description = "Reserve assigned MicroVM PCI functions before driver probing";
        wantedBy = ["initrd.target"];
        before = ["systemd-udev-trigger.service"];
        after = ["systemd-udevd.service"];
        unitConfig.DefaultDependencies = false;
        unitConfig.ConditionCredential = "!idr.workspace-id";
        serviceConfig.Type = "oneshot";
        script = pciOverride;
      };

      systemd.services = lib.mkMerge (
        lib.mapAttrsToList servicesFor cfgs
        ++ [(mkIf (pressureVMs != {}) {idr-microvm-memory = memoryManagement.service;})]
      );
      environment.systemPackages = lib.mapAttrsToList (name: _: instances.${name}.deployment.package) managementVMs;
      system.build.idrMicrovmDeployments = lib.mapAttrs (name: _: instances.${name}.deployment.worker) managementVMs;
      systemd.tmpfiles.rules = lib.mapAttrsToList (name: _: let
        inherit (instances.${name}) unitName instanceName;
      in "L+ /nix/var/nix/gcroots/${unitName}-booted - - - - ${config.microvm.stateDir}/${instanceName}/booted")
      cfgs;
      # Upstream privileged helpers execute through current/booted. Do not let
      # the unprivileged VMM replace those symlinks or their parent directory.
      systemd.tmpfiles.settings."10-microvm" =
        {
          # Preserve creation/removal of the upstream user's own VM directories,
          # while the sticky bit protects the root-owned instances below.
          "${config.microvm.stateDir}".d = {
            user = lib.mkForce "root";
            group = "kvm";
            mode = lib.mkForce "1775";
          };
        }
        // lib.mapAttrs' (name: _: let
          instanceName = instances.${name}.instanceName;
        in
          lib.nameValuePair "${config.microvm.stateDir}/${instanceName}" {
            d = {
              user = lib.mkForce "root";
              group = "kvm";
              mode = lib.mkForce "0750";
            };
          })
        cfgs;

      # This runner creates TAPs directly. Keep the inherited helper available
      # for other microvm.nix/libvirt guests or an explicit helper opt-in.
      security.wrappers.qemu-bridge-helper.enable = mkIf (
        !config.virtualisation.libvirtd.enable
        && lib.all (name: builtins.elem name (map (name: "idr-${name}") (builtins.attrNames cfgs))) (builtins.attrNames config.microvm.vms ++ config.microvm.autostart)
      ) (lib.mkDefault false);
      environment.etc."qemu/bridge.conf".text = mkIf (networkVMs != {}) (lib.mkDefault (lib.mkAfter "deny ${config.idr.microvm.network.bridgeName}"));
    })
  ];
}

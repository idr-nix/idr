{
  lib,
  pkgs,
  microvm,
  unitName,
  instanceName,
  vm,
  disks,
  bridgeName,
}: let
  runtimeDirectory = "/run/${unitName}";
  privateDirectory = "${runtimeDirectory}/private";
  apiSocket = "${privateDirectory}/api.sock";
  vsockSocket = "${privateDirectory}/deploy.sock";
  diskList = builtins.attrValues disks;
  storagePaths = map (disk: disk.path) diskList;
  managementEnabled = (vm.machine.config.idr.microvmGuest.enable or false) && (vm.machine.config.idr.microvmGuest.deployment.enable or false);
  shares = import ./virtiofs.nix {
    inherit lib;
    runtimeDirectory = privateDirectory;
    inherit (vm) shares;
  };
  pciAddresses = map lib.toLower (vm.pci.devices ++ vm.pci.bindOnlyDevices);
  interfaces = lib.optional vm.network.enable {
    type = "tap";
    id = vm.network.tapName;
    mac = vm.network.macAddress;
  };
  # Reuse the same TAP, PCI and virtiofs generators as a normal microvm.nix
  # guest, without importing its direct-kernel boot or host-shared Nix store.
  helpers =
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        "${microvm}/nixos-modules/microvm/interfaces.nix"
        "${microvm}/nixos-modules/microvm/pci-devices.nix"
        "${microvm}/nixos-modules/microvm/virtiofsd"
        {
          options = {
            networking.hostName = lib.mkOption {type = lib.types.str;};
            microvm = {
              interfaces = lib.mkOption {type = lib.types.listOf lib.types.attrs;};
              devices = lib.mkOption {type = lib.types.listOf lib.types.attrs;};
              shares = lib.mkOption {type = lib.types.listOf lib.types.attrs;};
              declaredRunner = lib.mkOption {type = lib.types.raw;};
              hypervisor = lib.mkOption {type = lib.types.str;};
              virtiofsd = lib.mkOption {type = lib.types.attrs;};
              binScripts = lib.mkOption {
                type = lib.types.attrsOf lib.types.lines;
                default = {};
              };
            };
          };
          config = {
            networking.hostName = instanceName;
            microvm = {
              inherit interfaces shares;
              devices = lib.optionals vm.pci.enable (map (path: {
                  bus = "pci";
                  inherit path;
                })
                pciAddresses);
              declaredRunner.passthru.tapMultiQueue = queuePairs > 1;
              hypervisor = "cloud-hypervisor";
              virtiofsd = {
                package = pkgs.virtiofsd;
                group = "kvm";
                threadPoolSize = 0;
                inodeFileHandles = "prefer";
                extraArgs = ["--sandbox=namespace"];
              };
            };
          };
        }
      ];
    }).config.microvm.binScripts;

  queuePairs =
    if vm.network.queuePairs == "auto"
    then lib.min vm.vcpu 8
    else vm.network.queuePairs;
  serialConsole = pkgs.stdenv.hostPlatform.isx86 || pkgs.stdenv.hostPlatform.isAarch64;
  consoleSocket = "socket=${privateDirectory}/console.sock";
  consoleOutput =
    if vm.console == "journal"
    then "tty"
    else consoleSocket;
  fixedArguments =
    [
      "--cpus"
      "boot=${toString vm.vcpu}"
      "--firmware"
      (toString vm.firmware)
    ]
    ++ lib.concatMap (disk: [
      "--disk"
      # Quote the path for Cloud Hypervisor's comma-separated option parser;
      # escapeShellArgs below handles the separate shell quoting layer.
      "path=\"${lib.replaceStrings ["\""] ["\"\""] disk.path}\",image_type=${disk.format},direct=${
        if disk.direct
        then "on"
        else "off"
      },serial=${disk.serial}"
    ])
    diskList
    ++ [
      "--console"
      (
        if vm.console == "both"
        # Keep existing disk/network PCI addresses when enabling the terminal.
        then "${consoleSocket},pci_device_id=31"
        else if serialConsole
        then "off"
        else consoleOutput
      )
      "--serial"
      (
        if serialConsole
        then
          if vm.console == "both"
          then "tty"
          else consoleOutput
        else "off"
      )
      "--api-socket"
      apiSocket
    ]
    ++ {
      warn = [];
      info = ["-v"];
      debug = ["-vv"];
      trace = ["-vvv"];
    }.${
      vm.logLevel
    }
    ++ lib.optionals vm.network.enable [
      "--net"
      "tap=${vm.network.tapName},mac=${vm.network.macAddress},num_queues=${toString (2 * queuePairs)},offload_tso=on,offload_ufo=on,offload_csum=on"
    ]
    ++ lib.optionals managementEnabled [
      "--vsock"
      "cid=${toString vm.deployment.vsockCid},socket=${vsockSocket}"
    ]
    ++ lib.concatMap (share: ["--fs" "tag=${share.tag},socket=${share.socket}"]) shares
    ++ lib.optionals vm.pci.enable (lib.concatMap (address: ["--device" "path=/sys/bus/pci/devices/${lib.toLower address},iommu=virtio"]) vm.pci.devices);

  memoryScript = ''
    host_mib=$(${pkgs.gawk}/bin/awk '$1 == "MemTotal:" {print int($2 / 1024)}' /proc/meminfo)
    maximum=${
      if vm.memory.maximumMiB == "host"
      then "$host_mib"
      else toString vm.memory.maximumMiB
    }
    floor=$(((maximum + 63) / 64 + 256))
    (( floor >= 512 )) || floor=512
    minimum=${
      if vm.memory.minimumMiB == "auto"
      then "$floor"
      else toString vm.memory.minimumMiB
    }
    initial=${
      if vm.memory.enable && vm.memory.initialMiB != null
      then toString vm.memory.initialMiB
      else "$maximum"
    }
    if (( maximum > host_mib || floor > minimum || minimum > initial || initial > maximum )); then
      echo "${unitName}: require boot floor ($floor MiB) <= minimum ($minimum MiB) <= initial ($initial MiB) <= maximum ($maximum MiB) <= host ($host_mib MiB)" >&2
      exit 1
    fi
    ${pkgs.jq}/bin/jq -n \
      --argjson enable ${lib.boolToString vm.memory.enable} \
      --argjson maximumMiB "$maximum" --argjson minimumMiB "$minimum" \
      --argjson initialMiB "$initial" --arg apiSocket ${lib.escapeShellArg apiSocket} \
      '{enable: $enable, maximumMiB: $maximumMiB, minimumMiB: $minimumMiB, initialMiB: $initialMiB, apiSocket: $apiSocket}' \
      > ${privateDirectory}/memory.json.tmp
    ${pkgs.coreutils}/bin/mv -f ${privateDirectory}/memory.json.tmp ${privateDirectory}/memory.json
  '';
  validatePci = ''
    # Validate all groups before the upstream helper unbinds any function.
    allowed=${lib.escapeShellArg (" " + lib.concatStringsSep " " pciAddresses + " ")}
    for address in ${lib.escapeShellArgs pciAddresses}; do
      group=/sys/bus/pci/devices/$address/iommu_group
      if [ ! -d "$group/devices" ]; then
        echo "PCI device $address has no IOMMU group" >&2
        exit 1
      fi
      for member in "$group"/devices/*; do
        case "$allowed" in
          *" ''${member##*/} "*) ;;
          *) echo "IOMMU group for $address also contains ''${member##*/}; include it in devices or bindOnlyDevices" >&2; exit 1 ;;
        esac
      done
    done
  '';
  validateDisks =
    lib.concatMapStringsSep "\n" (disk: ''
      storage_path=${lib.escapeShellArg disk.path}
      if [[ ! -f "$storage_path"${lib.optionalString (disk.format == "raw") " && ! -b \"$storage_path\""} ]]; then
        echo "${unitName}: disk $storage_path must be ${
        if disk.format == "raw"
        then "a regular file or block device"
        else "a regular file"
      }" >&2
        exit 1
      fi
      if ! [ -r "$storage_path" ] || ! [ -w "$storage_path" ]; then
        echo "${unitName}: disk $storage_path must be readable and writable by the MicroVM service user" >&2
        exit 1
      fi
    '')
    diskList;
  scripts =
    helpers
    // {
      microvm-run = ''
        set -euo pipefail
        ${validateDisks}
        ${pkgs.coreutils}/bin/install -d -m 0700 ${privateDirectory}
        ${memoryScript}
        for socket in ${privateDirectory}/{api,console,deploy}.sock; do
          if [ -e "$socket" ] && [ ! -S "$socket" ]; then
            echo "Refusing to replace non-socket file $socket" >&2
            exit 1
          fi
          ${pkgs.coreutils}/bin/rm -f -- "$socket"
        done
        ${lib.optionalString vm.network.enable ''
          # networkd attaches the upstream-created TAP to the configured bridge.
          deadline=$((SECONDS + 30))
          until [ "$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/readlink /sys/class/net/${vm.network.tapName}/master)")" = ${lib.escapeShellArg bridgeName} ]; do
            if (( SECONDS >= deadline )); then
              echo "Timed out waiting for TAP ${vm.network.tapName} on ${bridgeName}" >&2
              exit 1
            fi
            ${pkgs.coreutils}/bin/sleep 0.1
          done
        ''}
        memory_args=(--memory "size=''${maximum}M,shared=${
          if shares != []
          then "on"
          else "off"
        },hugepages=off,mergeable=off,prefault=off")
        ${lib.optionalString vm.memory.enable ''memory_args+=(--balloon "size=$((maximum - initial))M,free_page_reporting=on,deflate_on_oom=on")''}
        exec ${vm.package}/bin/cloud-hypervisor "''${memory_args[@]}" \
          ${lib.escapeShellArgs fixedArguments}
      '';
      microvm-shutdown = ''
        set -euo pipefail
        # ExecStop also runs after the guest has already shut down.
        if [[ -z "''${MAINPID:-}" ]]; then
          exit 0
        fi
        ${pkgs.coreutils}/bin/timeout 5 ${vm.package}/bin/ch-remote --api-socket ${lib.escapeShellArg apiSocket} power-button
        exec ${pkgs.util-linux}/bin/waitpid --exited --timeout ${toString vm.shutdownTimeoutSeconds} "$MAINPID"
      '';
    }
    // lib.optionalAttrs vm.pci.enable {
      pci-setup = ''
        set -euo pipefail
        ${validatePci}
        ${helpers.pci-setup}
      '';
    }
    // lib.optionalAttrs (shares != []) {
      virtiofsd-run = ''
        set -euo pipefail
        ${lib.concatMapStrings (share: ''
            if [ -e ${lib.escapeShellArg share.socket} ] && [ ! -S ${lib.escapeShellArg share.socket} ]; then
              echo ${lib.escapeShellArg "Refusing to replace non-socket file ${share.socket}"} >&2
              exit 1
            fi
            ${pkgs.coreutils}/bin/rm -f -- ${lib.escapeShellArg share.socket}
          '')
          shares}
        # The upstream supervisor normally writes relative to the VMM state
        # directory. Keep its root-owned metadata in a separate directory.
        # Foreground logging already reaches journald; its stdout socket cannot
        # be reopened as a log file.
        set -- --pidfile /run/${unitName}-virtiofsd/virtiofsd.pid \
          --logfile /dev/null --logfile_maxbytes 0 \
          --childlogdir /run/${unitName}-virtiofsd "$@"
        ${helpers.virtiofsd-run}
      '';
    };
  scriptPackages = lib.mapAttrs (name: text: pkgs.writeShellScript "${unitName}-${name}" text) scripts;
in
  pkgs.runCommand "${unitName}-runner" {
    meta.mainProgram = "microvm-run";
    passthru = {
      inherit scripts shares apiSocket privateDirectory vsockSocket managementEnabled storagePaths;
      memoryState = "${privateDirectory}/memory.json";
      supportsNotifySocket = false;
      canShutdown = true;
      tapMultiQueue = queuePairs > 1;
      hypervisor = "cloud-hypervisor";
      registerWithMachined = false;
    };
  } ''
    mkdir -p "$out/bin" "$out/share/microvm"
    ${lib.concatMapStrings (name: ''        ln -s ${scriptPackages.${name}} "$out/bin/${name}"
      '') (builtins.attrNames scriptPackages)}
    echo cloud-hypervisor > "$out/share/microvm/hypervisor"
  ''

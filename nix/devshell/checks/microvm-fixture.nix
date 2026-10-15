top: scenario: {
  config,
  lib,
  ...
}: let
  pkgs = config.node.pkgs;
  system = pkgs.stdenv.hostPlatform.system;
  runtime = scenario != "storage";
  management = scenario == "management";
  activation = scenario == "activation";
  offlineDeployment = management || activation;
  pathStorage = builtins.elem scenario ["storage-raw" "storage-qcow2" "storage-block"];
  suppliedStorage = pathStorage || activation;
  unusualShare = "/srv/shared space%id";
  mixedStorage = scenario == "storage-mixed";
  blockStorage = scenario == "storage-block" || mixedStorage;
  diskFormat =
    if scenario == "storage-qcow2"
    then "qcow2"
    else "raw";
  diskPath =
    if blockStorage
    then "/dev/disk/by-partlabel/idr-test-guest"
    else "/var/lib/microvm-disks/worker.${diskFormat}";
  imageQemu =
    (import "${top.inputs.nixpkgs}/nixos/lib/qemu-common.nix" {
      inherit lib;
      inherit (pkgs) stdenv;
    }).qemuBinary
    pkgs.qemu;
  keys = import "${top.inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs;
  secrets = lib.importJSON ./fixtures/microvm/worker.enc.json;
  knownHosts = builtins.toFile "microvm-test-known-hosts" ''
    vm-host,127.0.0.1,[127.0.0.1]:2222 ${keys.snakeOilEd25519PublicKey}
    worker,10.1.0.2 ${secrets.ssh_host_ed25519_key_pub_unencrypted}
  '';
  sshConfig = import ../../idr/deploy/ssh-config.nix {
    inherit lib;
    deploy.nodes.vm-host = {
      hostname = "127.0.0.1";
      sshUser =
        if scenario == "deployment"
        then "operator"
        else "root";
    };
    projectConfig = ''
      Host vm-host
        Port ${
        if scenario == "deployment"
        then "2222"
        else "22"
      }
      Host *
        UserKnownHostsFile ${knownHosts}
        IdentityFile /root/guest-key
        BatchMode yes
        StrictHostKeyChecking yes
        ConnectTimeout 5
    '';
  };
  imagePackages = project:
    (((import ../../idr/qemu/flake-module.nix top) {
      inherit lib;
      self = project;
    }).perSystem {inherit pkgs system;}).legacyPackages;
  cachedImageBuilder = let
    builder = import ./microvm-image.nix {
      inherit lib pkgs;
      machine = guest;
      imageBuilder = (imagePackages {nixosConfigurations.worker = guest;}).idrDiskoImagesScript.worker;
      sshHostKey = keys.snakeOilEd25519PrivateKey;
    };
  in
    if mixedStorage
    then
      pkgs.writeShellScript "microvm-test-counted-image-builder" ''
        echo build >> /var/lib/idr-test-image-builds
        exec ${builder} "$@"
      ''
    else builder;
  makeGuest = generation: let
    # Give the real IDR image builder the same machine registry as a project.
    project =
      top.self
      // {
        nixosConfigurations = {
          worker = machine;
          host.config = config.nodes.host;
        };
        legacyPackages.${system} =
          (imagePackages project)
          // lib.optionalAttrs runtime {idrDiskoImagesScript.worker = cachedImageBuilder;};
      };
    machine = top.inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        "${top.inputs.nixpkgs}/nixos/modules/profiles/minimal.nix"
        top.self.modules.nixos.disko
        top.self.modules.nixos.impermanence
        top.self.modules.nixos.preset
        top.self.modules.nixos.sops
        top.self.modules.nixos.microvm-guest
        ({pkgs, ...}: {
          # Prebuilt-generation updates need neither flake sources nor the
          # offline initrd compiler. Keep the image builder's installed profile.
          options.system.extraDependencies = lib.mkOption {
            apply =
              lib.filter (dependency:
                lib.isDerivation dependency && dependency != pkgs.kmod.inputDerivation);
          };
        })
        {
          networking.hostName = "worker";
          system.stateVersion = "26.05";
          boot.loader.timeout = 0;
          hardware.enableRedistributableFirmware = false;
          virtualisation.podman.enable = false;
          services.fail2ban.enable = false;
          services.journald.extraConfig = lib.mkIf management "ForwardToConsole=yes";
          services.openssh.enable = lib.mkIf offlineDeployment (lib.mkForce false);
          system.activationScripts.recordManagementGeneration = lib.mkIf management ''
            echo ${generation} > /run/idr-test-activated-generation
          '';
          systemd.services."idr-microvm-deployment@".environment.IDR_TEST_GENERATION = lib.mkIf management generation;
          idr.microvmGuest.deployment.authorizedKeys = lib.mkIf (management && generation != "initial") [
            "restrict ${keys.snakeOilEd25519PublicKey} management-test"
          ];
          nixpkgs.flake = {
            setFlakeRegistry = false;
            setNixPath = false;
          };
          idr.preset.base = {
            id = "000000000002";
            inputs = top.inputs // {self = project;};
            defaultSopsFile = ./fixtures/microvm/worker.enc.json;
            sopsRecipientMachines = [project.nixosConfigurations.host];
            preFormatFiles."/bootstrap-secret".key = "before_format";
            postFormatFiles."/persist/installed-secret".key = "after_format";
          };
          idr.microvmGuest = {
            enable = true;
            diskSizeMiB = 4096;
            network.ipv4Address = "10.1.0.2";
          };
          disko.devices.disk =
            {
              system.preCreateHook = ''test "$(cat /bootstrap-secret)" = before-format'';
            }
            // lib.optionalAttrs mixedStorage (lib.genAttrs ["data" "archive"] (name: {
              type = "disk";
              device = "/dev/disk/by-id/virtio-idr-${name}";
              imageName = name;
              imageSize = "256M";
              content = {
                type = "gpt";
                partitions.data = {
                  size = "100%";
                  content = {
                    type = "filesystem";
                    format = "ext4";
                    mountpoint = "/${name}";
                  };
                };
              };
            }));
          # Avoid another KVM nesting level while preparing the real guest disk.
          disko.imageBuilder.qemu = "${imageQemu} -machine accel=tcg -cpu ${
            if pkgs.stdenv.hostPlatform.isAarch64
            then "max,lpa2=off"
            else "max"
          } -smp 4";
          environment.persistence."/persist".directories = ["/var/lib/app"];
          users.users.root.openssh.authorizedKeys.keys = [keys.snakeOilEd25519PublicKey];
          environment.etc.generation.text = generation;
          system.preSwitchChecks.injected-failure = lib.mkIf (generation == "activation-fails") ''
            echo idr-test-activation-failure >&2
            exit 1
          '';
          environment.systemPackages = lib.optionals (!runtime) [pkgs.nixos-rebuild-ng];
          fileSystems."/mnt/shared" = lib.mkIf runtime {
            device = "shared";
            fsType = "virtiofs";
          };
          fileSystems."/mnt/unusual" = lib.mkIf (scenario == "deployment") {
            device = "unusual";
            fsType = "virtiofs";
          };
          specialisation.manual.configuration = lib.mkIf (!runtime) {
            environment.etc.generation.text = lib.mkForce "manual";
          };
        }
      ];
    };
  in
    machine;
  guest = makeGuest "initial";
  updatedGuest = makeGuest "host-updated";
  failedGuest = makeGuest "activation-fails";
  updatedDeployment = config.nodes.host.specialisation.staged.configuration.system.build.idrMicrovmDeployments.worker;
  guestActivation = import ../../idr/deploy/microvm-activation.nix {
    inherit lib pkgs;
    machine = guest;
    activation = top.inputs.deploy-rs.lib.${system}.activate.nixos guest;
  };
in {
  imports = with top.self.modules.nixosTest; [nix-store kvm-clock];
  name = "microvm-${scenario}";
  globalTimeout = 5 * 60;
  requiredFeatures.kvm = true;
  qemu.forceAccel = true;
  idr.test.storePaths = lib.optional (scenario == "deployment") guestActivation;

  nodes.host = {
    config,
    utils,
    ...
  }: let
    poolDevice = "/dev/disk/by-id/virtio-testpool";
    poolUnit = "${utils.escapeSystemdPath poolDevice}.device";
    blockDevice =
      if mixedStorage
      then "/dev/disk/by-id/virtio-testdisk"
      else poolDevice;
    blockUnit = "${utils.escapeSystemdPath blockDevice}.device";
  in {
    imports = [top.self.modules.nixos.microvm top.self.modules.nixos.preset top.self.modules.nixos.sops];
    idr.preset.base.defaultSopsFile = builtins.toFile "host-metadata.json" (builtins.toJSON {
      ssh_host_ed25519_key_age_pub_unencrypted = "age1rqz9lhprtuea2rglxfuuvgkccyzar25ta66gsea2mg86kuspcqdshcehps";
      ssh_host_ed25519_key_pub_unencrypted = keys.snakeOilEd25519PublicKey;
    });
    networking.hostId = "c0decafe";
    networking.useNetworkd = true;
    networking.useDHCP = false;
    boot.zfs.forceImportRoot = lib.mkIf (!suppliedStorage) false;
    microvm.stateDir = lib.mkIf (scenario == "recreation") "/srv/idr-test-microvms";
    virtualisation = {
      cores = 4;
      memorySize =
        if scenario == "memory"
        then 4096
        else 8192;
      diskSize = 16 * 1024;
      useNixStoreImage = true;
      emptyDiskImages =
        lib.optionals (!suppliedStorage || blockStorage) [
          {
            size = 8 * 1024;
            driveConfig.deviceExtraOpts.serial = "testpool";
          }
        ]
        ++ lib.optional mixedStorage {
          size = 8 * 1024;
          driveConfig.deviceExtraOpts.serial = "testdisk";
        };
      # Cloud Hypervisor needs nested KVM; the image builder uses TCG above.
      qemu.options = ["-cpu host"] ++ lib.optional pkgs.stdenv.hostPlatform.isAarch64 "-machine virtualization=on";
    };

    idr.microvm = {
      vms.worker = {
        machine = guest;
        deployment.autoUpdate = lib.mkIf (!offlineDeployment) false;
        network.enable = !offlineDeployment;
        vcpu = 1;
        console = lib.mkIf (scenario == "deployment") "both";
        logLevel = lib.mkIf (scenario == "deployment") "debug";
        disks =
          {
            system = {
              pool = lib.mkIf (!suppliedStorage) "testpool";
              path = lib.mkIf suppliedStorage diskPath;
              format = lib.mkIf suppliedStorage diskFormat;
            };
          }
          // lib.optionalAttrs mixedStorage {
            data = {
              path = "/var/lib/microvm-disks/worker-data.qcow2";
              format = "qcow2";
            };
            archive.path = "/dev/disk/by-partlabel/idr-test-guest";
          };
        memory = {
          maximumMiB = 1536;
          initialMiB = 768;
        };
        shares.shared = lib.mkIf runtime {source = "/srv/shared";};
        shares.unusual = lib.mkIf (scenario == "deployment") {source = unusualShare;};
      };
      # Trigger real pressure safely, with enough room for the test driver.
      memory = {
        reclaimBelowPercent = 20;
        releaseAbovePercent = 35;
        intervalSeconds = 1;
        cooldownSeconds = 1;
      };
    };
    virtualisation.fileSystems.${unusualShare} = lib.mkIf (scenario == "deployment") {
      device = "tmpfs";
      fsType = "tmpfs";
      options = ["noauto" "mode=0755"];
    };
    services.openssh = {
      enable = true;
      ports = [
        (
          if scenario == "deployment"
          then 2222
          else 22
        )
      ];
      hostKeys = [
        {
          path = "/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
    };
    systemd.tmpfiles.rules =
      [
        "C /root/guest-key 0600 root root - ${keys.snakeOilEd25519PrivateKey}"
        "C /etc/ssh/ssh_host_ed25519_key 0600 root root - ${keys.snakeOilEd25519PrivateKey}"
      ]
      ++ lib.optional suppliedStorage "d /srv/shared 0755 root root -";
    systemd.services.sshd-keygen.after = ["systemd-tmpfiles-setup.service"];
    users.users.root.openssh.authorizedKeys.keys = [keys.snakeOilEd25519PublicKey];
    users.users.operator = lib.mkIf (scenario == "deployment" || management) {
      isNormalUser = true;
      openssh.authorizedKeys.keys = [keys.snakeOilEd25519PublicKey];
    };
    security.sudo.extraRules = lib.mkIf management [
      {
        users = ["operator"];
        commands = [
          {
            command = "${updatedDeployment}/bin/idr-microvm-worker-connection deploy";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];
    environment.etc."microvm-ssh.conf".source = sshConfig.common;
    environment.systemPackages =
      [pkgs.jq pkgs.nixos-rebuild-ng config.idr.microvm.vms.worker.package]
      ++ lib.optional (scenario == "deployment") pkgs.python3;
    systemd.services.test-pool = lib.mkIf (!suppliedStorage) {
      requiredBy = ["zfs-import-testpool.service"];
      before = ["zfs-import-testpool.service"];
      after = [poolUnit "systemd-modules-load.service"];
      requires = [poolUnit];
      unitConfig = {
        DefaultDependencies = false;
        ConditionPathExists = "!/var/lib/test-pool-created";
      };
      path = [config.boot.zfs.package pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script =
        ''
          zpool create -f -O mountpoint=none testpool ${poolDevice}
        ''
        + lib.optionalString runtime ''
          zfs create -o mountpoint=/srv/shared testpool/shared
          zfs create -o mountpoint=/srv/shared/data -o snapdir=visible testpool/shared/data
          echo shared > /srv/shared/data/value
          zfs snapshot testpool/shared/data@initial
          cat /srv/shared/data/.zfs/snapshot/initial/value >/dev/null
          zfs clone -o mountpoint=/srv/shared/clone testpool/shared/data@initial testpool/clone
        ''
        + ''
          zpool export testpool
          touch /var/lib/test-pool-created
        '';
    };
    services.udev.extraRules = lib.mkIf blockStorage ''
      SUBSYSTEM=="block", ACTION=="add|change", ENV{ID_PART_ENTRY_NAME}=="idr-test-guest", OWNER="microvm", GROUP="root", MODE="0600"
    '';
    systemd.services.test-block-device = lib.mkIf blockStorage {
      requiredBy = ["idr-microvm-worker-install.service"];
      before = ["idr-microvm-worker-install.service"];
      after = [blockUnit "systemd-udevd.service"];
      requires = [blockUnit];
      unitConfig.ConditionPathExists = "!/var/lib/test-block-device-created";
      path = [pkgs.coreutils pkgs.systemd pkgs.util-linux];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        sfdisk ${blockDevice} <<'EOF'
        label: gpt
        size=8M, type=linux, name=idr-test-guard
        size=6G, type=linux, name=idr-test-guest
        EOF
        udevadm wait --timeout=20 --settle /dev/disk/by-partlabel/idr-test-guard ${diskPath}
        echo host-data > /dev/disk/by-partlabel/idr-test-guard
        sfdisk --dump ${blockDevice} > /var/lib/test-outer-partitions
        sha256sum /dev/disk/by-partlabel/idr-test-guard > /var/lib/test-guard.sha256
        touch /var/lib/test-block-device-created
      '';
    };
    systemd.services.test-pressure = lib.mkIf (scenario == "memory") {
      serviceConfig.Type = "exec";
      script = ''
        exec ${pkgs.python3}/bin/python3 - <<'PY'
        import mmap, signal
        with open('/proc/meminfo') as f:
            memory = {line.split()[0]: int(line.split()[1]) * 1024 for line in f}
        allocation = mmap.mmap(-1, memory['MemAvailable:'] - memory['MemTotal:'] // 10)
        for offset in range(0, len(allocation), 4096):
            allocation[offset] = 1
        signal.pause()
        PY
      '';
    };
    specialisation = lib.mkIf (builtins.elem scenario ["deployment" "lifecycle" "management" "activation" "recreation"]) {
      staged.configuration.idr.microvm.vms.worker = {
        machine = lib.mkForce updatedGuest;
        vcpu = lib.mkIf (!offlineDeployment) (lib.mkForce 2);
      };
      managed = lib.mkIf (scenario == "deployment") {
        configuration.idr.microvm.vms.worker = {
          machine = lib.mkForce updatedGuest;
          vcpu = lib.mkForce 2;
          deployment.restartOnHypervisorChange = true;
        };
      };
      broken = lib.mkIf management {
        configuration.idr.microvm.vms.worker.machine = lib.mkForce failedGuest;
      };
      manual = lib.mkIf management {
        configuration.idr.microvm.vms.worker.deployment.autoUpdate = false;
      };
    };
  };

  testScript =
    ''
      import shlex

      def ssh(command):
          return "${
        if offlineDeployment
        then "idr-microvm-worker-ssh"
        else "ssh -n -l root -F /etc/microvm-ssh.conf 10.1.0.2"
      } " + shlex.quote(command)

      vm = "microvm@idr-worker.service"
      host.start(allow_reboot=${
        if scenario == "lifecycle" || activation
        then "True"
        else "False"
      })
      host.wait_for_unit(vm)
      host.wait_until_succeeds(ssh("systemctl is-active multi-user.target"))
      assert host.succeed("stat -Lc %a ${config.nodes.host.idr.microvm.vms.worker.disks.system.path}").strip() == "600"
      assert host.succeed("stat -c %a /run/idr-microvm-worker/private").strip() == "700"
      host.fail("test -e /run/wrappers/bin/qemu-bridge-helper")
      boot_id = host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip()
      host.succeed(ssh("test -d /sys/firmware/efi && systemctl is-active earlyoom systemd-modules-load.service"))
    ''
    + lib.optionalString (!offlineDeployment) ''
      host.succeed(ssh("ip -4 -o addr show | grep -q 10.1.0.2/32"))
    ''
    + lib.optionalString pathStorage ''
      import json

      disk = "${diskPath}"
      install = "idr-microvm-worker-install.service"

      def check_outer_partitions():
          if ${
        if blockStorage
        then "True"
        else "False"
      }:
              host.succeed("sfdisk --dump /dev/disk/by-id/virtio-testpool | diff - /var/lib/test-outer-partitions")
              host.succeed("sha256sum --check /var/lib/test-guard.sha256")

      with subtest("configured disk storage boots without ZFS"):
          host.succeed("test ! -e /sys/module/zfs")
          dependencies = host.succeed(f"systemctl show {vm} {install} -p Requires -p Wants -p After")
          assert "zfs" not in dependencies, dependencies
          assert host.succeed("stat -Lc '%U:%G %a' " + disk).strip() == "microvm:root 600"
          info = json.loads(host.succeed("${pkgs.qemu-utils}/bin/qemu-img info --force-share --output=json " + disk))
          assert info["format"] == "${diskFormat}", info
          pid = host.succeed(f"systemctl show {vm} -p MainPID --value").strip()
          command = host.succeed("tr '\\0' ' ' < /proc/" + pid + "/cmdline")
          assert "image_type=${diskFormat},direct=off" in command, command
          assert host.succeed(ssh("blkid -p -s PTTYPE -o value /dev/disk/by-id/virtio-idr-system")).strip() == "gpt"
          assert host.succeed(ssh("cat /persist/installed-secret")).strip() == "after-format"
          host.succeed(ssh("test ! -e /bootstrap-secret"))
          host.succeed("test -z \"$(find /var/lib/idr-microvm-worker-install -name '.bootstrap-*' -print -quit)\"")
          check_outer_partitions()
          disk_inode = host.succeed("stat -Lc '%d:%i' " + disk).strip()
          machine_id = host.succeed(ssh("cat /etc/machine-id")).strip()
          host.succeed(ssh("cat /proc/sys/kernel/random/boot_id > /var/lib/app/value; touch /var/lib/discard-on-boot"))

      with subtest("restarting preserves the installed disk and persistent guest state"):
          host.succeed(f"systemctl stop {vm}")
          host.succeed(f"systemctl start {vm}")
          host.wait_until_succeeds(ssh("systemctl is-active multi-user.target"))
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() != boot_id
          assert host.succeed(ssh("cat /var/lib/app/value")).strip() == boot_id
          assert host.succeed(ssh("cat /etc/machine-id")).strip() == machine_id
          assert host.succeed("stat -Lc '%d:%i' " + disk).strip() == disk_inode
          host.succeed(ssh("test ! -e /var/lib/discard-on-boot"))
          host.succeed("journalctl -b -u " + install + " | grep -F 'Preserving existing disk'")
          check_outer_partitions()
    ''
    + lib.optionalString mixedStorage ''
      import json

      install = "idr-microvm-worker-install.service"
      disks = {
          "system": "/dev/zvol/testpool/idr-microvm-worker",
          "data": "/var/lib/microvm-disks/worker-data.qcow2",
          "archive": "/dev/disk/by-partlabel/idr-test-guest",
      }

      def check_host_partition():
          host.succeed("sfdisk --dump /dev/disk/by-id/virtio-testdisk | diff - /var/lib/test-outer-partitions")
          host.succeed("sha256sum --check /var/lib/test-guard.sha256")

      with subtest("one Disko build installs a zvol, QCOW2 image and host partition together"):
          assert host.succeed("wc -l < /var/lib/idr-test-image-builds").strip() == "1"
          for name, path in disks.items():
              assert host.succeed("stat -Lc '%U:%G %a' " + path).strip() == "microvm:root 600"
              assert host.succeed(ssh("blkid -p -s PTTYPE -o value /dev/disk/by-id/virtio-idr-" + name)).strip() == "gpt"
          info = json.loads(host.succeed("${pkgs.qemu-utils}/bin/qemu-img info --force-share --output=json " + disks["data"]))
          assert info["format"] == "qcow2", info
          pid = host.succeed(f"systemctl show {vm} -p MainPID --value").strip()
          command = host.succeed("tr '\\0' ' ' < /proc/" + pid + "/cmdline")
          for name in disks:
              assert "serial=idr-" + name in command, command
          for mount in ["data", "archive"]:
              assert host.succeed(ssh("findmnt -n -o FSTYPE -M /" + mount)).strip() == "ext4"
              parent = host.succeed(ssh("lsblk -no PKNAME $(findmnt -n -o SOURCE -M /" + mount + ")")).strip()
              assert host.succeed(ssh("readlink -f /dev/disk/by-id/virtio-idr-" + mount)).strip() == "/dev/" + parent
              host.succeed(ssh("cat /proc/sys/kernel/random/boot_id > /" + mount + "/value"))
          host.succeed(ssh("cat /proc/sys/kernel/random/boot_id > /var/lib/app/value"))
          assert host.succeed(ssh("cat /persist/installed-secret")).strip() == "after-format"
          volume_guid = host.succeed("zfs get -Hp -o value guid testpool/idr-microvm-worker").strip()
          image_inode = host.succeed("stat -Lc '%d:%i' " + disks["data"]).strip()
          check_host_partition()

      with subtest("restarting preserves every disk and the enclosing host partition table"):
          host.succeed(f"systemctl stop {vm}")
          host.succeed(f"systemctl start {vm}")
          host.wait_until_succeeds(ssh("systemctl is-active multi-user.target"))
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() != boot_id
          for path in ["/var/lib/app/value", "/data/value", "/archive/value"]:
              assert host.succeed(ssh("cat " + path)).strip() == boot_id
          assert host.succeed("zfs get -Hp -o value guid testpool/idr-microvm-worker").strip() == volume_guid
          assert host.succeed("stat -Lc '%d:%i' " + disks["data"]).strip() == image_inode
          assert host.succeed("wc -l < /var/lib/idr-test-image-builds").strip() == "1"
          host.succeed("test -z \"$(find /var/lib/idr-microvm-worker-install -name '.bootstrap-*' -print -quit)\"")
          check_host_partition()
    ''
    + lib.optionalString management ''
      import json

      deploy = "idr-microvm-worker-deploy.service"
      host_generation = host.succeed("readlink -f /run/current-system").strip()
      management_socket = "/run/idr-microvm-worker/private/deploy.sock"
      repository = "/home/operator/microvm-deploy-project"
      workers = {
          "initial": "${config.nodes.host.system.build.idrMicrovmDeployments.worker}",
          "updated": "${updatedDeployment}",
      }
      host.succeed("install -d -o operator -g users -m 0755 " + repository)

      def repository_guest(generation):
          # Reuse real deployment workers in a self-contained project, avoiding
          # another NixOS build inside the test VM.
          flake = "{ outputs = { self }: { nixosConfigurations.host.config.system.build.idrMicrovmDeployments.worker = builtins.storePath " + json.dumps(workers[generation]) + "; }; }"
          host.succeed("printf %s " + shlex.quote(flake) + " > " + repository + "/flake.nix")

      repository_guest("initial")
      manual_deploy = "idr-microvm-worker-deploy --flake " + repository + " -- --impure --offline"

      with subtest("host activation deploys without a guest network interface or network SSH"):
          assert host.succeed("systemctl show " + deploy + " -p InvocationID --value").strip() == ""
          host.succeed(f"nixos-rebuild test --store-path {host_generation} --no-reexec")
          host.wait_for_unit(deploy)
          assert host.succeed(ssh("cat /etc/generation")).strip() == "initial"
          host.succeed(ssh("test $(ls /sys/class/net | wc -l) = 1 && test -e /sys/class/net/lo"))
          host.succeed(ssh("test $(systemctl show sshd.service -p LoadState --value) = not-found"))
          host.succeed("journalctl -b -u " + deploy + " | grep -F 'Guest deployment confirmed.'")
          assert host.succeed("stat -c '%U:%G %a' " + management_socket).strip() == "root:root 600"
          assert host.succeed("stat -c %a /var/lib/idr-microvm-worker-deploy/current/identity").strip() == "600"
          host.succeed("idr-microvm-worker-ssh -T true")
          initial_system = host.succeed(ssh("readlink -f /run/current-system")).strip()

      with subtest("an unchanged deployment does not reactivate or alter profile history"):
          generations = host.succeed(ssh("nix-env -p /nix/var/nix/profiles/system --list-generations"))
          host.succeed(ssh("rm /run/idr-test-activated-generation"))
          host.succeed(manual_deploy)
          host.succeed(ssh("test ! -e /run/idr-test-activated-generation"))
          assert host.succeed(ssh("nix-env -p /nix/var/nix/profiles/system --list-generations")) == generations

      with subtest("only root and the host deployment key can reach management SSH"):
          for user in ["operator", "microvm"]:
              host.fail("runuser -u " + user + " -- idr-microvm-worker-ssh true")
              status, output = host.execute("runuser -u " + user + " -- ${pkgs.socat}/bin/socat - UNIX-CONNECT:" + management_socket + " </dev/null 2>&1")
              assert status != 0 and "Permission denied" in output, output
          host.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /root/wrong-key")
          direct_ssh = "ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${knownHosts} -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=5 -o ProxyUseFdpass=yes -o " + shlex.quote("ProxyCommand=${pkgs.systemd}/lib/systemd/systemd-ssh-proxy vsock-mux/" + management_socket + " %p")
          status, output = host.execute(direct_ssh + " -i /root/wrong-key root@worker true 2>&1")
          assert status != 0 and "Permission denied" in output, output
          status, output = host.execute(direct_ssh + " -i /root/guest-key -o HostKeyAlias=vm-host root@worker true 2>&1")
          assert status != 0 and "Host key verification failed" in output, output

      with subtest("host deployment updates the running guest without a reboot"):
          host.succeed(f"nixos-rebuild test --store-path {host_generation}/specialisation/staged --no-reexec")
          host.wait_for_unit(deploy)
          assert host.succeed(ssh("cat /etc/generation")).strip() == "host-updated"
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() == boot_id
          guest_profile = host.succeed(ssh("readlink -f /nix/var/nix/profiles/system")).strip()

      with subtest("a failed guest activation restores the installed profile"):
          # A guest can also be updated with ordinary nixos-rebuild. Its raw
          # system profile has no deploy-rs-specific activation entrypoint.
          host.succeed(ssh("nixos-rebuild switch --store-path /run/current-system --no-reexec"))
          guest_profile = host.succeed(ssh("readlink -f /nix/var/nix/profiles/system")).strip()
          # Leave an abandoned newer generation after a manual rollback. A
          # failed deployment must restore the running system, not that entry.
          host.succeed(ssh(f"nix-env -p /nix/var/nix/profiles/system --set {initial_system} && nix-env -p /nix/var/nix/profiles/system --rollback"))
          host.succeed(ssh("test ! -e /nix/var/nix/profiles/system/deploy-rs-activate && rm /run/idr-test-activated-generation"))
          host.fail(f"nixos-rebuild test --store-path {host_generation}/specialisation/broken --no-reexec")
          host.succeed("journalctl -b -u " + deploy + " | grep -F idr-test-activation-failure")
          assert host.succeed(ssh("cat /etc/generation")).strip() == "host-updated"
          assert host.succeed(ssh("cat /run/idr-test-activated-generation")).strip() == "host-updated"
          assert host.succeed(ssh("readlink -f /nix/var/nix/profiles/system")).strip() == guest_profile
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() == boot_id

      with subtest("automatic deployment can be disabled while manual recovery remains available"):
          host.succeed(f"nixos-rebuild test --store-path {host_generation}/specialisation/manual --no-reexec")
          assert host.succeed(ssh("cat /etc/generation")).strip() == "host-updated"
          manual_host_generation = host.succeed("readlink -f /run/current-system").strip()
          # Without --flake, the installed command builds the current project.
          host.succeed("cd " + repository + " && idr-microvm-worker-deploy -- --impure --offline")
          assert host.succeed(ssh("cat /etc/generation")).strip() == "initial"
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() == boot_id

      with subtest("a normal user builds the repository guest and elevates only deployment"):
          repository_guest("updated")
          host.fail("runuser -u operator -- sudo -n true")
          host.succeed("runuser -u operator -- sh -c " + shlex.quote("cd " + repository + " && " + manual_deploy))
          assert host.succeed(ssh("cat /etc/generation")).strip() == "host-updated"
          assert host.succeed("readlink -f /run/current-system").strip() == manual_host_generation
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() == boot_id
          host.succeed(ssh("test $(ls /sys/class/net | wc -l) = 1 && test -e /sys/class/net/lo"))

      with subtest("a failed repository build leaves the guest unchanged"):
          guest_profile = host.succeed(ssh("readlink -f /nix/var/nix/profiles/system")).strip()
          host.fail("idr-microvm-worker-deploy --flake /root/missing-project -- --offline")
          assert host.succeed(ssh("cat /etc/generation")).strip() == "host-updated"
          assert host.succeed(ssh("readlink -f /nix/var/nix/profiles/system")).strip() == guest_profile
    ''
    + lib.optionalString activation ''
      deploy = "idr-microvm-worker-deploy.service"
      host_generation = host.succeed("readlink -f /run/current-system").strip()

      with subtest("boot does not automatically deploy the host's guest generation"):
          assert host.succeed("systemctl show " + deploy + " -p InvocationID --value").strip() == ""
          host.succeed(ssh("test $(ls /sys/class/net | wc -l) = 1 && test -e /sys/class/net/lo"))
          host.succeed(ssh("test $(systemctl show sshd.service -p LoadState --value) = not-found"))
          host.succeed("${updatedDeployment}/bin/idr-microvm-worker-connection deploy")
          assert host.succeed(ssh("cat /etc/generation")).strip() == "host-updated"
          manual_profile = host.succeed(ssh("readlink -f /nix/var/nix/profiles/system")).strip()

      with subtest("the updater skips stopped guests without catching up at VM start"):
          host.succeed(f"systemctl stop {vm}")
          assert host.succeed(f"systemctl show {vm} -p ActiveState --value").strip() == "inactive"
          host.succeed(f"nixos-rebuild test --store-path {host_generation} --no-reexec")
          host.succeed("journalctl -b -u " + deploy + " | grep -F 'Skipping guest update: MicroVM is not running.'")
          skipped_invocation = host.succeed("systemctl show " + deploy + " -p InvocationID --value").strip()
          assert skipped_invocation
          # NixOS may already restart the VM when starting active targets at
          # the end of activation. Neither that start nor this one may deploy.
          host.succeed(f"systemctl start {vm}")
          host.wait_until_succeeds(ssh("systemctl is-active multi-user.target"))
          assert host.succeed(ssh("cat /etc/generation")).strip() == "host-updated"
          assert host.succeed(ssh("readlink -f /nix/var/nix/profiles/system")).strip() == manual_profile
          assert host.succeed("systemctl show " + deploy + " -p InvocationID --value").strip() == skipped_invocation
          restarted_boot_id = host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip()
          assert restarted_boot_id != boot_id

      with subtest("host reboot preserves a manually deployed guest generation"):
          host.reboot()
          host.wait_for_unit(vm)
          host.wait_until_succeeds(ssh("systemctl is-active multi-user.target"))
          assert host.succeed("readlink -f /run/current-system").strip() == host_generation
          assert host.succeed(ssh("cat /etc/generation")).strip() == "host-updated"
          assert host.succeed(ssh("readlink -f /nix/var/nix/profiles/system")).strip() == manual_profile
          assert host.succeed("systemctl show " + deploy + " -p InvocationID --value").strip() == ""
          rebooted_guest_boot_id = host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip()
          assert rebooted_guest_boot_id != restarted_boot_id

      with subtest("reactivating the same host generation updates its running guest"):
          host.succeed(f"nixos-rebuild test --store-path {host_generation} --no-reexec")
          host.wait_for_unit(deploy)
          assert host.succeed(ssh("cat /etc/generation")).strip() == "initial"
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() == rebooted_guest_boot_id
    ''
    + lib.optionalString (!runtime) ''
      with subtest("SOPS provisioning and a private Btrfs store"):
          assert host.succeed(ssh("cat /persist/installed-secret")).strip() == "after-format"
          host.succeed(ssh("test ! -e /bootstrap-secret"))
          host.succeed("test -z \"$(find /var/lib/idr-microvm-worker-install -name '.bootstrap-*' -print -quit)\"")
          assert host.succeed(ssh("findmnt -n -o FSTYPE -T /nix/store")).strip() == "btrfs"
          machine_id = host.succeed(ssh("cat /etc/machine-id")).strip()
          assert len(machine_id) == 32
          host.succeed(ssh("cat /proc/sys/kernel/random/boot_id > /var/lib/app/value; touch /var/lib/discard-on-boot"))
          store_path = host.succeed(ssh("nix-store --add /var/lib/app/value")).strip()
          host.fail("test -e " + shlex.quote(store_path))
          volume_guid = host.succeed("zfs get -Hp -o value guid testpool/idr-microvm-worker").strip()
          partition_size = int(host.succeed(ssh("blockdev --getsize64 /dev/disk/by-partlabel/disk-system-root")))
          filesystem_size = int(host.succeed(ssh("df -B1 --output=size / | tail -1")))

      with subtest("guest updates and state survive root reset and disk growth"):
          host.succeed(ssh("nixos-rebuild switch --store-path /run/current-system/specialisation/manual --no-reexec"))
          host.succeed(f"systemctl stop {vm}")
          host.succeed("zfs set volsize=6G testpool/idr-microvm-worker")
          host.succeed(f"systemctl start {vm}")
          host.wait_until_succeeds(ssh("test $(cat /etc/generation) = manual"))
          assert int(host.succeed(ssh("blockdev --getsize64 /dev/disk/by-partlabel/disk-system-root"))) > partition_size
          assert int(host.succeed(ssh("df -B1 --output=size / | tail -1"))) > filesystem_size
          host.succeed(ssh("test ! -e /var/lib/discard-on-boot"))
          assert host.succeed(ssh("cat /var/lib/app/value")).strip() == boot_id
          assert host.succeed(ssh("cat " + store_path)).strip() == boot_id
          assert host.succeed(ssh("cat /etc/machine-id")).strip() == machine_id
          assert host.succeed("zfs get -Hp -o value guid testpool/idr-microvm-worker").strip() == volume_guid
    ''
    + lib.optionalString runtime ''
      balloon = "ch-remote --api-socket /run/idr-microvm-worker/private/api.sock balloon-stats"
    ''
    + lib.optionalString (scenario == "deployment") ''
      host_generation = host.succeed("readlink -f /run/current-system").strip()
      with subtest("guest journal output continues while the interactive console is connected"):
          journal = f"journalctl -b -u {vm} --no-pager -o cat"
          host.wait_until_succeeds(journal + " | grep -E 'Welcome to .*NixOS'", timeout=10)
          host.succeed(journal + " | grep -E 'cloud-hypervisor: .*DEBUG:' > /dev/null")
          host.wait_until_succeeds(ssh("systemctl is-active serial-getty@hvc0.service"), timeout=15)
          console_socket = "/run/idr-microvm-worker/private/console.sock"
          host.succeed("test -S " + console_socket)
          status, output = host.execute("runuser -u operator -- ${pkgs.socat}/bin/socat - UNIX-CONNECT:" + console_socket + " </dev/null 2>&1")
          assert status != 0 and "Permission denied" in output, output
          console_test = """
      import re, socket, subprocess, sys, time

      def receive_until(client, expected):
          output = b""
          while expected not in output:
              chunk = client.recv(4096)
              assert chunk, output
              output += chunk

      for connection in range(2):
          with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
              client.settimeout(10)
              client.connect(sys.argv[1])
              client.sendall(b"\\r")
              receive_until(client, b"login:")
              if connection == 0:
                  subprocess.run(["sh", "-c", sys.argv[2]], check=True, timeout=10)
                  for _ in range(50):
                      journal = subprocess.check_output(["journalctl", "-b", "-u", sys.argv[3], "--no-pager", "-o", "cat"])
                      # UART bytes can interleave with complete VMM diagnostics.
                      journal = re.sub(rb"cloud-hypervisor: [^\\n]*\\n", b"", journal)
                      if b"idr-guest-console-marker" in journal:
                          break
                      time.sleep(0.1)
                  else:
                      raise AssertionError("guest console output did not reach the journal")
              else:
                  client.sendall(b"idr-console-test\\r")
                  receive_until(client, b"Password:")
      """
          host.succeed("python3 -c " + shlex.quote(console_test) + " " + shlex.quote(console_socket) + " " + shlex.quote(ssh("echo idr-guest-console-marker > /dev/console")) + " " + shlex.quote(vm))
          host.succeed(ssh("systemctl restart serial-getty@hvc0.service"))

      with subtest("nonroot jump host access and wrong-target deployment rejection"):
          host.fail("runuser -u operator -- test -r /dev/zvol/testpool/idr-microvm-worker")
          host.fail("runuser -u operator -- test -x /run/idr-microvm-worker/private")
          assert host.succeed("stat -c '%U:%G %a' /run/idr-microvm-worker").strip() == "root:kvm 750"
          host.fail("runuser -u microvm -- mv /run/idr-microvm-worker/private /run/idr-microvm-worker/replaced")
          host.succeed("ssh -n -l root -F /etc/microvm-ssh.conf -J vm-host 10.1.0.2 true")
          profile = host.succeed("readlink -f /nix/var/nix/profiles/system").strip()
          status, output = host.execute("${guestActivation}/activate-rs activate ${guestActivation} --profile-path /nix/var/nix/profiles/system --temp-path /tmp --confirm-timeout 30 2>&1")
          assert status != 0 and "the target is not this MicroVM" in output
          assert host.succeed("readlink -f /nix/var/nix/profiles/system").strip() == profile
          host.succeed("NIX_SSHOPTS='-F /etc/microvm-ssh.conf -l root -J vm-host' nix --extra-experimental-features nix-command copy --no-check-sigs --to ssh-ng://10.1.0.2 ${guestActivation}")
          host.succeed(ssh("${guestActivation}/activate-rs activate ${guestActivation} --profile-path /nix/var/nix/profiles/system --temp-path /tmp --confirm-timeout 30 --dry-activate"))

      with subtest("shared ZFS datasets, snapshots and clones"):
          # The virtiofs service must pull in this otherwise inactive mount.
          unusual_share = ${builtins.toJSON unusualShare}
          host.succeed("findmnt -rn --mountpoint " + shlex.quote(unusual_share))
          host.succeed("echo unusual > " + shlex.quote(unusual_share + "/value"))
          assert host.succeed(ssh("cat /mnt/unusual/value")).strip() == "unusual"
          host.succeed(ssh("echo from-guest > /mnt/unusual/written"))
          assert host.succeed("cat " + shlex.quote(unusual_share + "/written")).strip() == "from-guest"
          # Pool export removes the snapshot automount prepared by the fixture.
          host.succeed("cat /srv/shared/data/.zfs/snapshot/initial/value > /dev/null")
          for path in ["data/value", "data/.zfs/snapshot/initial/value", "clone/value"]:
              assert host.succeed(ssh("cat /mnt/shared/" + path)).strip() == "shared"
          host.succeed(ssh("echo from-guest > /mnt/shared/written"))
          assert host.succeed("cat /srv/shared/written").strip() == "from-guest"
          host.succeed("zfs clone -o mountpoint=/srv/shared/late testpool/shared/data@initial testpool/late")
          host.wait_until_succeeds(ssh("test $(cat /mnt/shared/late/value) = shared"))
          host.succeed(ssh("cat /proc/sys/kernel/random/boot_id > /var/lib/app/value"))
    ''
    + lib.optionalString (scenario == "memory") ''
      with subtest("Hypeman returns memory under host pressure and releases it again"):
          host.wait_for_unit("idr-microvm-memory.service")
          host.wait_until_succeeds(balloon + " | jq -e '.last_update > 0 and .stats.total_memory > 0 and .balloon_actual == 0'")
          host.succeed(ssh("truncate -s 512M /var/lib/cache && dd if=/var/lib/cache of=/dev/null bs=1M status=none"))
          cgroup = host.succeed(f"systemctl show {vm} -p ControlGroup --value").strip()
          resident = int(host.succeed(f"cat /sys/fs/cgroup{cgroup}/memory.current"))
          try:
              host.succeed("systemctl start test-pressure")
              host.wait_until_succeeds(balloon + " | jq -e '.balloon_actual >= 268435456'")
              host.wait_until_succeeds(f"test $(cat /sys/fs/cgroup{cgroup}/memory.current) -lt {resident - 67108864}")
              host.succeed(ssh("true"))
          finally:
              host.succeed("systemctl stop test-pressure")
          host.wait_until_succeeds(balloon + " | jq -e '.balloon_actual == 0'")
    ''
    + lib.optionalString (scenario == "deployment") ''
      with subtest("host updates preserve the guest and runner restarts are opt-in"):
          host.succeed(f"nixos-rebuild test --store-path {host_generation}/specialisation/staged --no-reexec")
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() == boot_id
          assert host.succeed(ssh("cat /etc/generation")).strip() == "initial"
          assert host.succeed(ssh("nproc")).strip() == "1"
          host.succeed(ssh("test -w /mnt/shared && test $(cat /mnt/shared/data/value) = shared"))
          host.succeed(f"nixos-rebuild test --store-path {host_generation}/specialisation/managed --no-reexec")
          host.wait_until_succeeds(ssh("test $(cat /etc/generation) = initial && test $(nproc) = 2"))
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() != boot_id
          host.succeed(ssh("ip -4 -o addr show | grep -q 10.1.0.2/32"))
          assert host.succeed(ssh("cat /var/lib/app/value")).strip() == boot_id
          host.succeed(ssh("systemctl is-active earlyoom && test -w /mnt/shared"))
          host.wait_until_succeeds(balloon + " | jq -e '.balloon_actual == 0'")

      with subtest("upgrading the old runtime layout rejects a private directory symlink"):
          host.succeed(f"systemctl stop {vm}")
          host.succeed("install -d -m 0755 -o root -g root /srv/idr-virtiofs-sentinel")
          # Recreate the previous user-owned parent, then attack it as microvm.
          host.succeed("chown microvm:kvm /run/idr-microvm-worker")
          host.succeed("runuser -u microvm -- mv /run/idr-microvm-worker/private /run/idr-microvm-worker/original")
          host.succeed("runuser -u microvm -- ln -s /srv/idr-virtiofs-sentinel /run/idr-microvm-worker/private")
          status, output = host.execute(f"systemctl start {vm}")
          assert host.succeed("stat -c '%U:%G %a' /srv/idr-virtiofs-sentinel").strip() == "root:root 755"
          assert status != 0, output
          assert host.succeed("stat -c '%U:%G %a' /run/idr-microvm-worker").strip() == "root:kvm 750"
    ''
    + lib.optionalString (scenario == "recreation") ''
      runner_directory = "${config.nodes.host.microvm.stateDir}/idr-worker"
      host_generation = host.succeed("readlink -f /run/current-system").strip()
      original_runner = host.succeed("readlink -f " + runner_directory + "/current").strip()
      volume_guid = host.succeed("zfs get -Hp -o value guid testpool/idr-microvm-worker").strip()
      host.succeed(ssh("cat /proc/sys/kernel/random/boot_id > /var/lib/app/value"))

      def remove_runner_state():
          host.succeed(f"systemctl stop {vm}")
          for helper in ["microvm-set-booted@idr-worker", "microvm-tap-interfaces@idr-worker", "microvm-virtiofsd@idr-worker", "idr-microvm-worker-install"]:
              host.wait_until_succeeds(f"test $(systemctl show {helper}.service -p ActiveState --value) = inactive")
          host.succeed("rm -rf -- " + shlex.quote(runner_directory))
          host.fail("test -e " + shlex.quote(runner_directory))

      def check_runner_state():
          assert host.succeed("stat -c '%U:%G %a' " + runner_directory).strip() == "root:kvm 750"
          host.succeed("test -L " + runner_directory + "/current && test -x " + runner_directory + "/current/bin/microvm-run")

      def check_preserved_guest():
          host.wait_until_succeeds(ssh("test $(cat /etc/generation) = initial && test $(nproc) = 2"))
          assert host.succeed(ssh("cat /var/lib/app/value")).strip() == boot_id
          assert host.succeed("zfs get -Hp -o value guid testpool/idr-microvm-worker").strip() == volume_guid

      with subtest("the runner installer rejects a directory replaced by a symlink"):
          remove_runner_state()
          host.succeed("install -d -m 0750 -o root -g root /srv/idr-recreation-sentinel")
          host.succeed("runuser -u microvm -- ln -s /srv/idr-recreation-sentinel " + shlex.quote(runner_directory))
          host.fail("systemctl start install-microvm-idr-worker.service")
          host.succeed("test -z \"$(ls -A /srv/idr-recreation-sentinel)\"")
          host.succeed("rm -- " + shlex.quote(runner_directory))
          host.succeed("systemctl reset-failed install-microvm-idr-worker.service")

      with subtest("host deployment recreates missing runner state in a custom directory"):
          host.succeed(f"nixos-rebuild test --store-path {host_generation}/specialisation/staged --no-reexec")
          check_runner_state()
          staged_runner = host.succeed("readlink -f " + runner_directory + "/current").strip()
          assert staged_runner != original_runner
          host.succeed(f"systemctl start {vm}")
          check_preserved_guest()
          restarted_boot_id = host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip()
          assert restarted_boot_id != boot_id

      with subtest("starting the VM directly also recreates missing runner state"):
          remove_runner_state()
          host.succeed(f"systemctl start {vm}")
          check_runner_state()
          assert host.succeed("readlink -f " + runner_directory + "/current").strip() == staged_runner
          check_preserved_guest()
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() != restarted_boot_id
    ''
    + lib.optionalString (scenario == "lifecycle") ''
      with subtest("guest shutdown releases helpers and the next start uses the staged runner"):
          host_generation = host.succeed("readlink -f /run/current-system").strip()
          host.succeed(ssh("cat /proc/sys/kernel/random/boot_id > /var/lib/app/value"))
          host.succeed(f"nixos-rebuild test --store-path {host_generation}/specialisation/staged --no-reexec")
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() == boot_id
          status, output = host.execute(ssh("systemctl poweroff --no-block"))
          assert status in [0, 255], output  # SSH can disconnect during shutdown.
          host.wait_until_succeeds(f"test $(systemctl show {vm} -p ActiveState --value) = inactive")
          host.wait_until_succeeds("test $(systemctl show microvm-set-booted@idr-worker.service -p ActiveState --value) = inactive")
          assert host.succeed(f"systemctl show {vm} -p Result --value").strip() == "success"
          host.succeed(f"systemctl start {vm}")
          host.wait_until_succeeds(ssh("test $(cat /etc/generation) = initial && test $(nproc) = 2"))
          assert host.succeed(ssh("cat /proc/sys/kernel/random/boot_id")).strip() != boot_id
          host.succeed(ssh("echo from-guest > /mnt/shared/written"))

      with subtest("host reboot imports the existing VM pool"):
          volume_guid = host.succeed("zfs get -Hp -o value guid testpool/idr-microvm-worker").strip()
          host.reboot()
          host.wait_for_unit(vm)
          host.wait_until_succeeds(ssh("systemctl is-active multi-user.target"))
          assert host.succeed("zfs get -Hp -o value guid testpool/idr-microvm-worker").strip() == volume_guid
          assert host.succeed(ssh("cat /var/lib/app/value")).strip() == boot_id
          assert host.succeed(ssh("cat /mnt/shared/written")).strip() == "from-guest"
    '';
}

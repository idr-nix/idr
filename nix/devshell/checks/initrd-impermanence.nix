top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.initrd-impermanence = pkgs.testers.runNixOSTest ({hostPkgs, ...}: let
      dataDisk =
        if hostPkgs.stdenv.hostPlatform.isDarwin
        then "/dev/vdc"
        else "/dev/vdb";
    in {
      imports = [
        (lib.modules.importApply ../../testing/arm-image-builder.nix {})
        top.self.modules.nixosTest.nix-store
        top.self.modules.nixosTest.kvm-clock
      ];
      name = "initrd-impermanence";
      globalTimeout = 10 * 60;

      defaults = {
        imports = [
          top.self.modules.nixos.disko
          top.self.modules.nixos.impermanence
          (lib.modules.importApply ../../preset/impermanence/impermanence.nix top)
        ];
        virtualisation = {
          emptyDiskImages = [1024];
          memorySize = 2048;
          useBootLoader = true;
          useEFIBoot = true;
          mountHostNixStore = !hostPkgs.stdenv.hostPlatform.isDarwin;
        };
        boot.loader.systemd-boot.enable = true;
        boot.loader.timeout = 0;
        boot.initrd.systemd.enable = true;
      };

      nodes.zfs = {config, ...}: {
        networking.hostId = "deadbeef";
        boot.supportedFilesystems = ["zfs"];
        boot.zfs.devNodes = "/dev";
        environment.systemPackages = [config.boot.zfs.package];
        specialisation.impermanent.configuration = {
          idr.preset.impermanence.rootDataset = "testpool/root";
          virtualisation.fileSystems = {
            "/" = lib.mkForce {
              device = "testpool/root";
              fsType = "zfs";
            };
            "/persist" = {
              device = "testpool/persist";
              fsType = "zfs";
              neededForBoot = true;
            };
          };
        };
      };

      nodes.btrfs = {pkgs, ...}: {
        environment.systemPackages = [pkgs.btrfs-progs];
        specialisation.impermanent.configuration = {
          idr.preset.impermanence.rootSubvolume = "@root";
          virtualisation.fileSystems = {
            "/" = lib.mkForce {
              device = dataDisk;
              fsType = "btrfs";
              options = ["subvol=@root"];
            };
            "/nix" = {
              device = dataDisk;
              fsType = "btrfs";
              options = ["subvol=@nix"];
              neededForBoot = true;
            };
            "/persist" = {
              device = dataDisk;
              fsType = "btrfs";
              options = ["subvol=@persist"];
              neededForBoot = true;
            };
          };
        };
      };

      testScript = {nodes, ...}: ''
        zfs.start(allow_reboot=True)
        btrfs.start(allow_reboot=True)
        zfs.wait_for_unit("multi-user.target")
        btrfs.wait_for_unit("multi-user.target")

        with subtest("prepare ZFS root without a blank snapshot"):
            zfs.succeed(
                "zpool create -f -o cachefile=none -O mountpoint=none testpool ${dataDisk}",
                "zfs create -o mountpoint=legacy -o compression=lz4 -o xattr=sa "
                "-o idr:test=preserved testpool/root",
                "zfs create -o mountpoint=legacy testpool/persist",
                "mkdir -p /mnt/root /mnt/persist",
                "mount -t zfs testpool/root /mnt/root",
                "touch /mnt/root/discard-before-first-boot /mnt/root/.hidden",
                "mkdir /mnt/root/nested && touch /mnt/root/nested/immutable",
                "chattr +i /mnt/root/nested/immutable",
                "mount -t zfs testpool/persist /mnt/persist",
                "echo keep-zfs > /mnt/persist/marker",
                "umount /mnt/root /mnt/persist",
            )
            zfs.fail("zfs list testpool/root@blank")

        with subtest("prepare Btrfs root and persistent sibling subvolumes"):
            btrfs.succeed(
                "mkfs.btrfs -f ${dataDisk}",
                "mkdir -p /mnt/root",
                "mount ${dataDisk} /mnt/root",
                "btrfs subvolume create /mnt/root/@root",
                "btrfs subvolume create /mnt/root/@root/nested",
                "btrfs subvolume create /mnt/root/@root/nested/child",
                "btrfs subvolume create /mnt/root/@nix",
                "btrfs subvolume create /mnt/root/@persist",
                "touch /mnt/root/@root/discard-before-first-boot /mnt/root/@root/.hidden",
                "echo nested > /mnt/root/@root/nested/child/marker",
                "echo keep-btrfs > /mnt/root/@persist/marker",
                "echo keep-nix > /mnt/root/@nix/marker",
                "umount /mnt/root",
            )

        for machine, system in [
            (zfs, "${nodes.zfs.specialisation.impermanent.configuration.system.build.toplevel}"),
            (btrfs, "${nodes.btrfs.specialisation.impermanent.configuration.system.build.toplevel}"),
        ]:
            with subtest(f"{machine.name}: first real initrd reset boots the installed system"):
                machine.succeed(
                    f"nix-env --profile /nix/var/nix/profiles/system --set {system}",
                    f"{system}/bin/switch-to-configuration boot",
                    "sync",
                )
                machine.reboot()
                machine.wait_for_unit("multi-user.target")
                machine.succeed(
                    "test ! -e /discard-before-first-boot",
                    "test ! -e /.hidden",
                    "test ! -e /nested",
                    f'test "$(cat /persist/marker)" = keep-{machine.name}',
                )
                if machine is zfs:
                    machine.succeed(
                        "zfs list testpool/root@blank",
                        'test "$(zfs get -H -o value mountpoint testpool/root)" = legacy',
                        'test "$(zfs get -H -o value compression testpool/root)" = lz4',
                        'test "$(zfs get -H -o value xattr testpool/root)" = sa',
                        'test "$(zfs get -H -o value idr:test testpool/root)" = preserved',
                    )
                    assert machine.succeed("zfs list -H -o name -r testpool").splitlines() == [
                        "testpool", "testpool/persist", "testpool/root",
                    ]
                else:
                    machine.succeed('test "$(cat /nix/marker)" = keep-nix')

            with subtest(f"{machine.name}: later boots reset root while preserving state"):
                machine.succeed("touch /discard-on-reboot /.hidden-on-reboot")
                if machine is btrfs:
                    machine.succeed("btrfs subvolume create /nested")
                    machine.succeed("btrfs subvolume create /nested/child")
                else:
                    machine.succeed("mkdir -p /nested/child")
                machine.succeed("touch /nested/child/marker", "sync")
                machine.reboot()
                machine.wait_for_unit("multi-user.target")
                machine.succeed(
                    "test ! -e /discard-on-reboot",
                    "test ! -e /.hidden-on-reboot",
                    "test ! -e /nested",
                    f'test "$(cat /persist/marker)" = keep-{machine.name}',
                )
                if machine is btrfs:
                    machine.succeed('test "$(cat /nix/marker)" = keep-nix')
      '';
    });
  };
}

top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.preset-dataset-deploy = pkgs.testers.runNixOSTest {
      imports = [top.self.modules.nixosTest.disk-storage];
      name = "preset-dataset-deploy";
      node.pkgsReadOnly = false;
      globalTimeout = 10 * 60;

      nodes.machine = {config, ...}: {
        imports = builtins.attrValues top.self.modules.nixos;
        _module.args.inputs = top.inputs;
        virtualisation = {
          memorySize = 2048;
          cores = 2;
          emptyDiskImages = [512];
        };
        networking.useDHCP = false;
        idr.preset.base = {
          id = "24a1c017a17e";
          inherit (top) inputs;
        };
        services.openssh.enable = false;
        boot.initrd.network.ssh.enable = false;
        virtualisation.podman.enable = false;
        boot.supportedFilesystems = ["zfs"];
        boot.zfs.devNodes = lib.mkForce "/dev";
        disko.devices.zpool.p1 = {
          type = "zpool";
          rootFsOptions.mountpoint = "none";
        };
        environment.persistence."/persist".directories = ["/var/lib/nixos"];
        systemd.services.initialize-test-pool = {
          requiredBy = ["disko-zfs.service"];
          before = ["disko-zfs.service" "zfs-import-p1.service"];
          after = ["dev-vdb.device" "systemd-modules-load.service"];
          requires = ["dev-vdb.device"];
          unitConfig.DefaultDependencies = false;
          path = [config.boot.zfs.package];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            if ! zpool list p1; then
              zpool import -N -d /dev p1 || zpool create -f -O mountpoint=none p1 /dev/vdb
            fi
          '';
        };

        specialisation.updated.configuration = {
          users.users.my-app = {
            isSystemUser = true;
            group = "my-app";
          };
          users.groups.my-app = {};
          disko.devices.zpool.p1.datasets.my-app = {
            type = "zfs_fs";
            options = {
              mountpoint = "legacy";
              compression = "lz4";
            };
            mountpoint = "/p1/my-app";
          };
          # The test VM runner replaces fileSystems with this option.
          virtualisation.fileSystems."/p1/my-app" = {
            device = "p1/my-app";
            fsType = "zfs";
          };
          environment.persistence."/persist".directories = [
            {
              directory = "/var/lib/my-app";
              user = "my-app";
              group = "my-app";
              mode = "0700";
            }
          ];
          systemd.tmpfiles.rules = ["d /p1/my-app 0700 my-app my-app -"];
          systemd.services.my-app = {
            wantedBy = ["multi-user.target"];
            unitConfig.RequiresMountsFor = ["/p1/my-app" "/var/lib/my-app"];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "my-app";
              Group = "my-app";
            };
            script = "test -w /p1/my-app && test -w /var/lib/my-app";
          };
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("multi-user.target")
        machine.fail("zfs list p1/my-app")
        machine.succeed("zfs create -o mountpoint=none p1/keep-me")

        with subtest("activate a new dataset declaration on a running server"):
            try:
                machine.succeed(
                    "/run/current-system/specialisation/updated/bin/switch-to-configuration test",
                    timeout=180,
                )
            except Exception:
                print(machine.execute("stat -c '%U %G %a %n' /p1/my-app /var/lib/my-app /persist/var/lib/my-app"))
                print(machine.execute("systemctl --failed --no-pager"))
                raise
            machine.wait_for_unit("multi-user.target")
            machine.wait_for_unit("my-app.service")
            assert machine.succeed("findmnt -n -o SOURCE /p1/my-app").strip() == "p1/my-app"
            assert machine.succeed("zfs get -H -o value compression p1/my-app").strip() == "lz4"
            machine.succeed("zfs list p1/keep-me")
            for directory in ["/p1/my-app", "/var/lib/my-app"]:
                assert machine.succeed(f"stat -c '%U %G %a' {directory}").strip() == "my-app my-app 700"
            machine.succeed("su -s /bin/sh my-app -c 'printf deployed > /p1/my-app/deployed'")
            assert machine.succeed("cat /p1/my-app/deployed") == "deployed"
            machine.fail("systemctl is-active emergency.target")
      '';
    };
  };
}

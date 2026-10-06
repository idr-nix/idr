top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.preset-container-web = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./preset-container-fixture.nix {inherit top;})
      ];

      name = "preset-container-web";

      nodes.machine = {config, ...}: {
        virtualisation.emptyDiskImages = [512];
        # The VM runner replaces fileSystems; keep the application's real mount.
        virtualisation.fileSystems."/p1/my-app" = {
          device = "p1/my-app";
          fsType = "zfs";
        };
        boot.supportedFilesystems = ["zfs"];
        boot.zfs.devNodes = lib.mkForce "/dev";
        disko.devices.zpool.p1 = {
          type = "zpool";
          rootFsOptions.mountpoint = "none";
          datasets.my-app = {
            type = "zfs_fs";
            options.mountpoint = "legacy";
            mountpoint = "/p1/my-app";
          };
        };
        # Stand in for the pool created at installation on this disposable disk.
        # The application dataset is created by the preset's Disko service.
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
        users.users.nginx = {
          isSystemUser = true;
          uid = config.ids.uids.nginx;
          group = "nginx";
        };
        users.groups.nginx.gid = config.ids.gids.nginx;
        systemd.tmpfiles.rules = ["d /p1/my-app 0750 nginx nginx -"];

        containers.example = {
          bindMounts."/var/lib/my-app" = {
            hostPath = "/p1/my-app";
            isReadOnly = false;
          };
          config = {pkgs, ...}: {
            services.nginx = {
              enable = true;
              virtualHosts.localhost = {
                listen = [
                  {
                    addr = "127.0.0.1";
                    port = 8080;
                  }
                ];
                root = pkgs.writeTextDir "index.html" "Hello from a container";
                locations."/data/".alias = "/var/lib/my-app/";
              };
            };
          };
        };
      };

      testScript = ''
        machine.start(allow_reboot=True)
        machine.wait_for_unit("container@example.service")
        boot_id = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()

        with subtest("start the documented nginx container automatically on the host network"):
            machine.wait_until_succeeds("curl --fail --silent http://127.0.0.1:8080/")
            assert machine.succeed("curl --fail --silent http://127.0.0.1:8080/") == "Hello from a container"
            assert machine.succeed("findmnt -n -o SOURCE /p1/my-app").strip() == "p1/my-app"

        with subtest("write application data through the persistent container bind mount"):
            machine.succeed(
                "nixos-container run example -- su -s /bin/sh nginx -c "
                "\"printf 'persistent container data' > /var/lib/my-app/data.txt\""
            )
            assert machine.succeed("cat /p1/my-app/data.txt") == "persistent container data"
            assert machine.succeed("curl --fail --silent http://127.0.0.1:8080/data/data.txt") == "persistent container data"

        with subtest("restart the host and retain the container's application data"):
            machine.reboot()
            machine.wait_for_unit("container@example.service")
            assert machine.succeed("cat /proc/sys/kernel/random/boot_id").strip() != boot_id
            machine.wait_until_succeeds("curl --fail --silent http://127.0.0.1:8080/data/data.txt")
            assert machine.succeed("curl --fail --silent http://127.0.0.1:8080/data/data.txt") == "persistent container data"
            assert machine.succeed("stat -c '%U %G' /p1/my-app/data.txt").strip() == "nginx nginx"
      '';
    };
  };
}

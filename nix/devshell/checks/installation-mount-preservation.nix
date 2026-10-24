{
  pkgs,
  diskoModule,
}: let
  disk = "/dev/vdb";
  layout =
    (pkgs.nixos {
      imports = [diskoModule];
      system.stateVersion = "26.05";
      disko.enableConfig = false;
      disko.devices.disk.existing = {
        type = "disk";
        device = disk;
        content = {
          type = "gpt";
          partitions.root = {
            size = "100%";
            content = {
              type = "luks";
              name = "installation-preservation";
              passwordFile = "/run/installation-test-key";
              extraFormatArgs = ["--pbkdf" "pbkdf2" "--pbkdf-force-iterations" "1000"];
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    }).config;
  installation = import ../../scripts/idr-anywhere.nix {
    diskoMode = "mount";
    expectedDisks = [disk];
    projectRoot = "/unused";
    node = "test-machine";
    flake = {
      inputs.nixpkgs = {
        inherit (pkgs) lib;
        legacyPackages.${pkgs.stdenv.hostPlatform.system} = pkgs;
      };
      deploy.nodes.test-machine.profiles.system.path.idr.meta = {
        inherit (layout.system.build) mountScript mountScriptNoDeps;
        system = pkgs.stdenv.hostPlatform.system;
        nixSettings = {};
        disko.disks.root.path = disk;
        formatMount = throw "Mount-only installation must not evaluate formatting";
        diskoScript = throw "Mount-only installation must not evaluate the wipe fallback";
      };
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "installation-mount-preservation";
    globalTimeout = 10 * 60;

    nodes.machine = {
      virtualisation = {
        emptyDiskImages = [256];
        memorySize = 1024;
      };
      boot.kernelModules = ["dm-crypt"];
      environment.systemPackages = with pkgs; [cryptsetup util-linux e2fsprogs];
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("multi-user.target")

      def fingerprint():
          return machine.succeed(
              "sfdisk --dump ${disk}; "
              "cryptsetup luksDump --dump-json-metadata ${disk}1"
          )

      def close():
          machine.succeed("umount /mnt", "cryptsetup close installation-preservation")

      with subtest("prepare an existing encrypted filesystem with persisted data"):
          machine.succeed(
              "printf test-key > /run/installation-test-key",
              "${layout.system.build.diskoScript}",
              "printf 'preserve existing data\\n' > /mnt/persisted-marker",
              "sync",
          )
          before = fingerprint()
          close()

      for script in [
          "${installation.system.build.mountScript}",
          "${installation.system.build.mountScriptNoDeps}",
      ]:
          with subtest(f"{script}: mount existing data without changing disk or LUKS metadata"):
              machine.succeed(script)
              assert machine.succeed("cat /mnt/persisted-marker") == "preserve existing data\n"
              assert fingerprint() == before
              close()

          with subtest(f"{script}: wrong unlock key fails without formatting or wipe fallback"):
              machine.succeed("printf wrong-key > /run/installation-test-key")
              machine.fail(script)
              assert fingerprint() == before
              machine.fail("test -e /dev/mapper/installation-preservation")
              machine.succeed("printf test-key > /run/installation-test-key", script)
              assert machine.succeed("cat /mnt/persisted-marker") == "preserve existing data\n"
              close()
    '';
  }

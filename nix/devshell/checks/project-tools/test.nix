{
  pkgs,
  self,
  ...
}: let
  inherit (pkgs) lib;
  devshell = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
  testScript = name:
    pkgs.writeText "project-tools-${name}.nu" (builtins.readFile (./. + "/${name}.nu"));
  buildAndBoot = pkgs.writeText "project-tools-build-and-boot.nu" ''
    do --capture-errors {
      ^$nu.current-exe -n ${testScript "images"}
      ^$nu.current-exe -n ${testScript "boot"}
    }
  '';
in
  pkgs.testers.runNixOSTest {
    name = "project-tools";
    globalTimeout = 90 * 60;

    nodes.machine = {
      virtualisation = {
        diskSize = 60 * 1024;
        memorySize = 24 * 1024;
        cores = 16;
        useNixStoreImage = true;
        writableStore = true;
        writableStoreUseTmpfs = false;
        additionalPaths = [devshell];
        qemu.options = ["-cpu" "host"];
      };
      nix = {
        package = pkgs.lixPackageSets.latest.lix;
        settings = {
          experimental-features = ["nix-command" "flakes"];
          sandbox = true;
          substituters = lib.mkForce [];
        };
      };
      environment.systemPackages = [pkgs.git];
      networking.useDHCP = false;
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.succeed("git config --global user.name Test")
      machine.succeed("git config --global user.email test@example.invalid")

      # QEMU must not inherit the serial driver's controlling terminal.
      def in_project(command, timeout=1800):
          return machine.succeed(
              "cd /tmp/project && setsid nix --offline -L develop -c " + command + " </dev/null",
              timeout=timeout,
          )

      with subtest("create an offline project and machine"):
          machine.succeed("${devshell}/bin/idr-mk-project /tmp/project", timeout=1800)
          in_project("idr-mk-machine test-machine")
          in_project("nu -n ${testScript "configure"} ${./project-module.nix}")

      with subtest("operator access, generated files, and declarative key rotation"):
          in_project("nu -n ${testScript "secrets"}")

      # Rotation changes the machine's public keys, so refresh the devshell's
      # generated SSH configuration and Process Compose readiness probes.
      with subtest("build and boot mirrored encrypted disks, preserving only persistent state"):
          in_project("nu -n ${buildAndBoot}", timeout=3600)

      with subtest("rotate keys, copy new identities, and deploy to the running machine"):
          in_project("nu -n ${testScript "rotate-running-machine"}")

      with subtest("reboot the rotated system and replace the cached VM client key"):
          in_project("nu -n ${testScript "restart"}")
    '';
  }

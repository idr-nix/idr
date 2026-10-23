top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    guestPkgs = pkgs.pkgsLinux;
    keyboardModule = lib.modules.importApply ../../preset/base/initrd-keyboard.nix top;
    baseOption = {
      options.idr.preset.base.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
    };
    evaluate = extra:
      (guestPkgs.nixos [
        baseOption
        keyboardModule
        {
          boot.initrd.systemd.enable = lib.mkDefault true;
          system.stateVersion = "26.05";
        }
        extra
      ]).config;
    defaults = evaluate {};
    disabled = map evaluate [
      {idr.preset.base.enable = false;}
      {boot.isContainer = true;}
      {boot.initrd.enable = false;}
      {boot.initrd.systemd.enable = false;}
      {boot.plymouth.enable = true;}
      {boot.initrd.unl0kr.enable = false;}
    ];
    drm = evaluate {boot.initrd.unl0kr.settings.general.backend = "drm";};
    touch = evaluate {services.iptsd.enable = true;};
  in {
    checks = {
      initrd-keyboard-options = assert lib.assertMsg defaults.boot.initrd.unl0kr.enable "The base preset must offer an initrd keyboard by default";
      assert lib.assertMsg (builtins.all (config: !config.boot.initrd.unl0kr.enable) disabled) "The initrd keyboard must honor exclusions and native opt-out";
      assert lib.assertMsg (lib.hasInfix ''SUBSYSTEM=="drm"'' drm.boot.initrd.services.udev.rules) "A custom DRM backend must activate on DRM devices";
      assert lib.assertMsg (builtins.elem "uinput" touch.boot.initrd.kernelModules && !(touch.boot.initrd.systemd.services."iptsd@".unitConfig.DefaultDependencies)) "IPTSD must run before the real root is mounted";
      assert lib.assertMsg (touch.boot.initrd.systemd.contents."/etc/iptsd.conf".source == touch.environment.etc."iptsd.conf".source) "IPTSD must share its configured calibration with the initrd";
        pkgs.runCommand "initrd-keyboard-options" {} ''touch "$out"'';
      initrd-keyboard = pkgs.testers.runNixOSTest ({hostPkgs, ...}: let
        luksDevice =
          if hostPkgs.stdenv.hostPlatform.isDarwin
          then "/dev/vdc"
          else "/dev/vdb";
      in {
        imports = [
          (lib.modules.importApply ../../testing/arm-image-builder.nix {})
          top.self.modules.nixosTest.nix-store
          top.self.modules.nixosTest.kvm-clock
        ];
        name = "initrd-keyboard";

        defaults = {pkgs, ...}: {
          imports = [baseOption keyboardModule];
          virtualisation = {
            emptyDiskImages = [512];
            useBootLoader = true;
            mountHostNixStore = !hostPkgs.stdenv.hostPlatform.isDarwin;
            useEFIBoot = true;
          };
          boot.loader.systemd-boot.enable = true;
          boot.initrd.systemd.enable = true;
          boot.initrd.systemd.extraBin.pgrep = "${pkgs.procps}/bin/pgrep";
          environment.systemPackages = [pkgs.cryptsetup];

          specialisation.encrypted.configuration = {
            testing.initrdBackdoor = true;
            boot.initrd.luks.devices = lib.mkVMOverride {
              cryptroot.device = luksDevice;
            };
            virtualisation.rootDevice = "/dev/mapper/cryptroot";
            virtualisation.fileSystems."/".autoFormat = true;
          };
        };

        nodes = {
          graphical = {pkgs, ...}: {
            virtualisation.qemu.options = lib.optional pkgs.stdenv.hostPlatform.isx86 "-vga virtio";
            services.iptsd.enable = true;
          };
          headless = {pkgs, ...}: {
            options.virtualisation.qemu.options = lib.mkOption {
              apply = lib.filter (argument: argument != "-device virtio-gpu-pci");
            };
            config.virtualisation.qemu.options = lib.optional pkgs.stdenv.hostPlatform.isx86 "-vga none";
          };
        };

        testScript = {nodes, ...}: ''
          import time
          from pathlib import Path
          from typing import Any

          start_all()
          initial_vt = ""
          for machine, system in [
              (graphical, "${nodes.graphical.specialisation.encrypted.configuration.system.build.toplevel}"),
              (headless, "${nodes.headless.specialisation.encrypted.configuration.system.build.toplevel}"),
          ]:
              with subtest(f"{machine.name}: boot without an unlock request"):
                  machine.wait_for_unit("multi-user.target")
                  if machine is graphical:
                      initial_vt = machine.succeed("cat /sys/class/tty/tty0/active").strip()
                  machine.succeed(
                      "echo -n eeee | cryptsetup luksFormat -q --iter-time=1 ${luksDevice} -",
                      "echo -n eeee | cryptsetup luksOpen -q ${luksDevice} cryptroot",
                      "mkfs.ext4 /dev/mapper/cryptroot",
                      f"nix-env --profile /nix/var/nix/profiles/system --set {system}",
                      f"{system}/bin/switch-to-configuration boot",
                      "sync",
                  )
                  machine.crash()
                  machine.start()

          with subtest("unlock encrypted root using only the on-screen keyboard"):
              graphical.wait_for_unit("unl0kr-agent.service", timeout=60)
              graphical.wait_until_succeeds(
                  f'test "$(cat /sys/class/tty/tty0/active)" != {initial_vt}', timeout=30,
              )
              graphical.succeed(
                  "test -e /dev/fb0",
                  "test -c /dev/uinput",
                  "test -r /etc/iptsd.conf",
                  "test -x /nix/store/*-iptsd-*/bin/iptsd",
                  "test -x /nix/store/*-iptsd-*/bin/iptsd-check-device",
                  "test -d /nix/store/*-iptsd-*/share/iptsd",
                  "systemctl cat iptsd@.service",
                  "systemctl --no-ask-password --no-block restart systemd-ask-password-console.service",
              )
              time.sleep(2)
              graphical.screenshot("keyboard")
              screen = Path(graphical.out_dir) / "keyboard.ppm"
              graphical.send_monitor_command(f"screendump {screen}")
              magic, dimensions, maximum, pixels = screen.read_bytes().split(b"\n", 3)
              screen.unlink()
              assert magic == b"P6" and maximum == b"255"
              width, height = map(int, dimensions.split())
              header = {
                  pixels[3 * (y * width + x):3 * (y * width + x + 1)]
                  for y in range(height // 8, height // 5)
                  for x in range(width // 4, 3 * width // 4)
              }
              assert len(header) == 1, "Console output overwrote the unlock screen"

              def click(x, y):
                  assert graphical.qmp_client is not None
                  press: Any = [
                      {"type": "abs", "data": {"axis": "x", "value": int(x * 32767)}},
                      {"type": "abs", "data": {"axis": "y", "value": int(y * 32767)}},
                      {"type": "btn", "data": {"down": True, "button": "left"}},
                  ]
                  graphical.qmp_client.send("input-send-event", {"events": press})
                  time.sleep(0.1)
                  release: Any = [
                      {"type": "btn", "data": {"down": False, "button": "left"}},
                  ]
                  graphical.qmp_client.send("input-send-event", {"events": release})
                  time.sleep(0.1)

              for _ in range(4):
                  click(0.25, 0.65)
              graphical.screenshot("entered")
              click(0.9, 0.9)
              graphical.wait_until_succeeds("test -e /dev/mapper/cryptroot", timeout=30)
              graphical.wait_until_succeeds(
                  f'test "$(cat /sys/class/tty/tty0/active)" = {initial_vt}', timeout=30,
              )
              graphical.switch_root()
              graphical.wait_for_unit("multi-user.target")
              graphical.succeed("findmnt -n -S /dev/mapper/cryptroot --mountpoint /")
              assert graphical.succeed("cat /sys/class/tty/tty0/active").strip() == initial_vt

          with subtest("serial console unlock remains available while the keyboard is active"):
              graphical.succeed("sync")
              graphical.crash()
              graphical.start()
              graphical.wait_for_unit("unl0kr-agent.service", timeout=60)
              graphical.wait_for_unit("systemd-ask-password-console.service", timeout=30)
              graphical.wait_until_succeeds("test -f /run/systemd/ask-password/ask.*", timeout=30)
              graphical.send_console("eeee\n")
              graphical.switch_root()
              graphical.wait_for_unit("multi-user.target")
              graphical.succeed("findmnt -n -S /dev/mapper/cryptroot --mountpoint /")

          with subtest("a failed graphical agent restores physical keyboard unlock"):
              graphical.succeed("sync")
              graphical.crash()
              graphical.start()
              graphical.wait_for_unit("unl0kr-agent.service", timeout=60)
              keyboard_vt = graphical.succeed("cat /sys/class/tty/tty0/active").strip()
              graphical.succeed("systemctl --no-ask-password --no-block restart systemd-ask-password-console.service")
              graphical.wait_until_succeeds(
                  f"pgrep -f 'systemd-tty-ask-password-agent --watch --console=/dev/{keyboard_vt}($| )'", timeout=30,
              )
              graphical.succeed(
                  "systemctl --no-ask-password stop unl0kr-agent.path",
                  "systemctl --no-ask-password kill --kill-whom=main --signal=SIGKILL unl0kr-agent.service",
              )
              graphical.wait_until_succeeds(
                  f'test "$(cat /sys/class/tty/tty0/active)" = {initial_vt}', timeout=30,
              )
              graphical.wait_until_succeeds(
                  f"pgrep -f 'systemd-tty-ask-password-agent --watch --console=/dev/{initial_vt}($| )'", timeout=30,
              )
              graphical.send_chars("eeee\n")
              graphical.switch_root()
              graphical.wait_for_unit("multi-user.target")
              graphical.succeed("findmnt -n -S /dev/mapper/cryptroot --mountpoint /")

          with subtest("headless machines retain console unlock without starting the keyboard"):
              headless.wait_for_unit("systemd-ask-password-console.service", timeout=30)
              headless.wait_until_succeeds("test -f /run/systemd/ask-password/ask.*", timeout=30)
              headless.succeed("test ! -e /dev/fb0")
              headless.fail("systemctl is-active unl0kr-agent.path", "systemctl is-active unl0kr-agent.service")
              headless.send_console("eeee\n")
              headless.switch_root()
              headless.wait_for_unit("multi-user.target")
              headless.succeed("findmnt -n -S /dev/mapper/cryptroot --mountpoint /")
        '';
      });
    };
  };
}

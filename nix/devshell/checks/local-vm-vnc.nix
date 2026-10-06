top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-vnc = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        name = "local-vm-vnc";
        defaults = {pkgs, ...}: {
          services.dbus.enable = true;
          fonts.packages = [pkgs.dejavu_fonts];
          environment = {
            systemPackages = [pkgs.xdotool pkgs.python3];
            variables.DISPLAY = ":0";
            etc."idr-vnc-password.py".source = ./local-vm-vnc-password.py;
          };
          systemd.services.idr-test-display = {
            description = "Headless display for the real VNC client";
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              ExecStart = "${pkgs.xorg-server}/bin/Xvfb :0 -screen 0 1024x768x24 -nolisten tcp";
              Restart = "on-failure";
            };
          };
        };

        testScript = ''
          import shlex

          # Repeated probes share one live devshell and retain their outer timeout.
          def retry_in_shell(command):
              return "bash -c " + shlex.quote("until " + command + "; do sleep 1; done")

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("idr-test-display.service")
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6"
          )
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          shell = "cd /root/project && nix --offline develop -c "
          machine.succeed(
              "sed -i '/networking.hostName =/a\\    idr.meta.preset.base.qemu.vnc.enable = true;' "
              "/root/project/nix/machine/test-machine/configuration.nix"
          )
          machine.succeed("git -C /root/project add nix/machine/test-machine/configuration.nix")
          daemon_started = False
          try:
              with subtest("enable VNC, enter the shell, and start the VM"):
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  readiness = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                  )
                  machine.succeed(
                      shell + retry_in_shell("bash -o pipefail -c " + shlex.quote(readiness)), timeout=900,
                  )

              with subtest("open the display with the actual idr-vnc Remmina client"):
                  machine.succeed(
                      shell + "bash -c " + shlex.quote(
                          "idr-vnc test-machine > /tmp/idr-vnc.log 2>&1 &"
                      ), timeout=120,
                  )
                  window = machine.wait_until_succeeds(
                      "xdotool search --onlyvisible --name 'test-machine'", timeout=120,
                  ).splitlines()[0]
                  machine.succeed("xdotool windowfocus --sync " + window + " key Return")

              with subtest("log in and send keyboard input through the VNC display"):
                  machine.succeed("xdotool type --clearmodifiers root && xdotool key Return")
                  machine.succeed(
                      shell + retry_in_shell("ssh vm-test-machine " + shlex.quote(
                          "stty -F /dev/tty1 -a | grep -q -- ' -echo '"
                      )), timeout=120,
                  )
                  # Type the decrypted test password through stdin, never an argv or log.
                  machine.succeed(shell + "python /etc/idr-vnc-password.py", timeout=120)
                  machine.succeed(
                      shell + retry_in_shell("ssh vm-test-machine pgrep -t tty1 -x bash"), timeout=120,
                  )
                  command = "printf '%s\\n' idr-vnc-connected > /run/idr-vnc-result"
                  machine.succeed(
                      "xdotool type --clearmodifiers -- " + shlex.quote(command)
                      + " && xdotool key Return"
                  )
                  machine.succeed(
                      shell + retry_in_shell("ssh vm-test-machine " + shlex.quote(
                          "test \"$(cat /run/idr-vnc-result)\" = idr-vnc-connected"
                      )), timeout=120,
                  )
          except Exception:
              print(machine.execute("cat /tmp/idr-vnc.log"))
              raise
          finally:
              if daemon_started:
                  machine.succeed(shell + "idr down", timeout=120)
                  machine.wait_until_fails(
                      shell + "idr process get vm-test-machine -o json", timeout=60,
                  )
        '';
      });
    };
  };
}

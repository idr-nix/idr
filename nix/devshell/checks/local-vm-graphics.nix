top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-graphics = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "local-vm-graphics";
        defaults = {pkgs, ...}: {
          services.dbus.enable = true;
          fonts.packages = [pkgs.dejavu_fonts];
          environment = {
            systemPackages = [pkgs.xdotool];
            variables.DISPLAY = ":0";
          };
          systemd.services.idr-test-display = {
            description = "Headless display for the QEMU graphical window";
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              ExecStart = "${pkgs.xorg-server}/bin/Xvfb :0 -screen 0 1024x768x24 -nolisten tcp";
              Restart = "on-failure";
            };
          };
        };

        testScript = ''
          import shlex

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

          shell = "cd /root/project && direnv exec . "
          machine.succeed("cd /root/project && direnv allow")
          machine.succeed(
              "sed -i '/networking.hostName =/a\\    idr.meta.preset.base.qemu.graphics = true;' "
              "/root/project/nix/machine/test-machine/configuration.nix"
          )
          machine.succeed("git -C /root/project add nix/machine/test-machine/configuration.nix")
          daemon_started = False
          try:
              with subtest("enable graphics, enter the shell, and start the VM"):
                  machine.succeed(shell + "idr -D", timeout=600)
                  daemon_started = True
                  readiness = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                  )
                  machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(readiness), timeout=900,
                  )

              with subtest("the running guest opens its actual QEMU graphical window"):
                  window = machine.wait_until_succeeds(
                      "xdotool search --onlyvisible --name '^QEMU'", timeout=120,
                  ).splitlines()[0]
                  window_pid = machine.succeed("xdotool getwindowpid " + window).strip()
                  assert window_pid.isdecimal(), window_pid
                  executable = machine.succeed("readlink /proc/" + window_pid + "/exe").strip()
                  assert "qemu-system-" in executable, executable
                  assert machine.succeed(
                      shell + "ssh vm-test-machine hostname", timeout=120,
                  ).strip() == "test-machine"
          except Exception:
              if daemon_started:
                  print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
              raise
          finally:
              if daemon_started:
                  machine.succeed(shell + "idr down", timeout=120)
                  machine.wait_until_succeeds(
                      shell + "bash -c " + shlex.quote(
                          "idr process get vm-test-machine -o json; status=$?; "
                          'test "$status" -gt 0 && test "$status" -lt 124'
                      ), timeout=60,
                  )
        '';
      });
    };
  };
}

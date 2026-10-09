top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-serial = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        python = config.node.pkgs.python3.withPackages (ps: [ps.pexpect]);
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "local-vm-serial";
        defaults = {
          environment = {
            systemPackages = [python];
            etc."idr-serial-console.py".source = ./local-vm-serial-console.py;
          };
        };

        testScript = ''
          import shlex

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6"
          )
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          shell = "cd /root/project && direnv exec . "
          machine.succeed("cd /root/project && direnv allow")
          daemon_started = False
          try:
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

              with subtest("log in through idr-serial and disconnect with each documented escape"):
                  # Automate the interactive login without writing its password to the test log.
                  machine.succeed(
                      shell + "${python}/bin/python /etc/idr-serial-console.py", timeout=300,
                  )

              with subtest("read guest serial output through the documented process logs command"):
                  machine.succeed(
                      shell + "bash -ec " + shlex.quote(
                          "idr process logs --tail 1000 vm-test-machine > /tmp/idr-serial.log && "
                          "grep -Fq '__IDR_SERIAL_GUEST__:test-machine' /tmp/idr-serial.log"
                      ), timeout=120,
                  )
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

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
    application = pkgs.writeText "my-app.nix" ''
      top: {pkgs, ...}: {
        users.users.my-app = { isSystemUser = true; group = "my-app"; };
        users.groups.my-app = {};

        disko.devices.zpool.p1.datasets.my-app = {
          type = "zfs_fs";
          options = { mountpoint = "legacy"; compression = "lz4"; };
          mountpoint = "/p1/my-app";
        };
        systemd.tmpfiles.rules = ["d /p1/my-app 0700 my-app my-app -"];

        environment.persistence."/persist".directories = [{
          directory = "/var/lib/my-app";
          user = "my-app";
          group = "my-app";
          mode = "0700";
        }];
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
      }
    '';
  in {
    checks = {
      local-vm-persistence = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        name = "local-vm-persistence";

        testScript = ''
          import shlex

          # Keep repeated probes in one live devshell instead of re-evaluating it.
          def retry_in_shell(command):
              return "bash -c " + shlex.quote("until " + command + "; do sleep 1; done")

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          shell = "cd /root/project && nix --offline develop -c "

          def remote(command):
              return shell + "ssh vm-test-machine " + shlex.quote(command)

          daemon_started = False
          try:
              with subtest("start the generated machine with its existing disk layout"):
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
                  machine.fail(remote("zfs list p1/my-app"), timeout=120)
                  machine.succeed(remote("zfs create -o mountpoint=/p1/keep-me p1/keep-me"), timeout=120)

              with subtest("deploy a new application dataset and its persistence declaration"):
                  machine.succeed(
                      "cd /root/project && cp ${application} nix/machine/test-machine/my-app.nix && "
                      "sed -i '/hardware-specific.nix/a\\      ./my-app.nix' "
                      "nix/machine/test-machine/configuration.nix && git add nix/machine/test-machine"
                  )
                  machine.succeed(shell + "deploy -s .#vm-test-machine -- -L", timeout=900)
                  machine.succeed(remote("systemctl is-active my-app.service && zfs list p1/keep-me"))
                  assert machine.succeed(remote("findmnt -n -o SOURCE /p1/my-app")).strip() == "p1/my-app"
                  assert machine.succeed(remote("zfs get -H -o value compression p1/my-app")).strip() == "lz4"

              with subtest("write application data as its service user and a file on ephemeral root"):
                  owner = machine.succeed(remote("id -u my-app")).strip()
                  group = machine.succeed(remote("id -g my-app")).strip()
                  for directory in ["/p1/my-app", "/var/lib/my-app"]:
                      assert machine.succeed(remote(f"stat -c '%u %g %a' {directory}")).strip() == f"{owner} {group} 700"
                  write_data = (
                      "printf 'dataset data' > /p1/my-app/data && "
                      "printf 'persistent state' > /var/lib/my-app/state"
                  )
                  machine.succeed(remote("su -s /bin/sh my-app -c " + shlex.quote(write_data)))
                  machine.succeed(remote("touch /root/ephemeral-root-test"))
                  boot_id = machine.succeed(remote("cat /proc/sys/kernel/random/boot_id")).strip()
                  machine_id = machine.succeed(remote("cat /etc/machine-id")).strip()
                  assert boot_id and machine_id

              with subtest("reboot into a blank root while retaining application files and ownership"):
                  machine.succeed(remote("reboot"), timeout=120)
                  machine.succeed(shell + retry_in_shell("ssh vm-test-machine " + shlex.quote(
                      "test \"$(cat /proc/sys/kernel/random/boot_id)\" != " + shlex.quote(boot_id)
                      + " && systemctl is-active my-app.service"
                  )), timeout=900)
                  machine.succeed(remote("test ! -e /root/ephemeral-root-test"))
                  assert machine.succeed(remote("cat /p1/my-app/data")) == "dataset data"
                  assert machine.succeed(remote("cat /var/lib/my-app/state")) == "persistent state"
                  assert machine.succeed(remote("cat /persist/var/lib/my-app/state")) == "persistent state"
                  assert machine.succeed(remote("id -u my-app")).strip() == owner
                  assert machine.succeed(remote("id -g my-app")).strip() == group
                  assert machine.succeed(remote("cat /etc/machine-id")).strip() == machine_id
                  for path in ["/p1/my-app/data", "/var/lib/my-app/state"]:
                      assert machine.succeed(remote(f"stat -c '%u %g' {path}")).strip() == f"{owner} {group}"
          except Exception:
              if daemon_started:
                  print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
              raise
          finally:
              if daemon_started:
                  machine.succeed(shell + "idr down", timeout=120)
                  machine.wait_until_fails(shell + "idr process get vm-test-machine -o json", timeout=60)
        '';
      });
    };
  };
}

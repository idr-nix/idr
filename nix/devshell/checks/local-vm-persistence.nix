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
        inherit (pkgs.stdenv.hostPlatform) isDarwin;
        archiveDirectory =
          if isDarwin
          then "/tmp/test-output"
          else "/tmp/shared";
        networkPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "local-vm-persistence";

        # Export directly to the driver output on both supported host platforms.
        nodeDefaults.virtualisation.sharedDirectories.test-output = lib.mkIf isDarwin {
          source = ''"$out"'';
          target = archiveDirectory;
          securityModel = "none";
        };

        testScript = ''
          import json
          import shlex

          ${lib.optionalString (!isDarwin) ''
            machine.shared_dir = machine.out_dir
          ''}
          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("systemd-networkd.service")
          machine.wait_until_succeeds(
              "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
          )

          shell = "cd /root/project && direnv exec . "
          machine.succeed("cd /root/project && direnv allow")

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
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(readiness), timeout=900,
                  )
                  factory_system, factory_profile = machine.succeed(remote(
                      "readlink -f /run/current-system && "
                      "readlink -f /nix/var/nix/profiles/system"
                  ), timeout=120).splitlines()
                  assert factory_system.startswith("/nix/store/"), factory_system
                  assert factory_profile.startswith("/nix/store/"), factory_profile
                  machine.fail(remote("zfs list p1/my-app"), timeout=120)
                  machine.succeed(remote("zfs create -o mountpoint=/p1/keep-me p1/keep-me"), timeout=120)

              with subtest("deploy a new application dataset and its persistence declaration"):
                  machine.succeed(
                      "cd /root/project && cp ${application} nix/machine/test-machine/my-app.nix && "
                      "sed -i '/hardware-specific.nix/a\\      ./my-app.nix' "
                      "nix/machine/test-machine/configuration.nix && git add nix/machine/test-machine"
                  )
                  machine.succeed(shell + "deploy -s .#vm-test-machine -- -L", timeout=900)
                  source, compression = machine.succeed(remote(
                      "systemctl is-active my-app.service >/dev/null && "
                      "zfs list p1/keep-me >/dev/null && "
                      "findmnt -n -o SOURCE /p1/my-app && "
                      "zfs get -H -o value compression p1/my-app"
                  )).splitlines()
                  assert source.strip() == "p1/my-app"
                  assert compression.strip() == "lz4"
                  deployed_system, deployed_profile = machine.succeed(remote(
                      "readlink -f /run/current-system && "
                      "readlink -f /nix/var/nix/profiles/system"
                  ), timeout=120).splitlines()
                  assert deployed_system.startswith("/nix/store/"), deployed_system
                  assert deployed_profile.startswith("/nix/store/"), deployed_profile
                  assert deployed_system != factory_system
                  assert deployed_profile != factory_profile

              with subtest("write application data as its service user and a file on ephemeral root"):
                  owner, group, dataset_permissions, state_permissions = machine.succeed(remote(
                      "id -u my-app && id -g my-app && "
                      "stat -c '%u %g %a' /p1/my-app && "
                      "stat -c '%u %g %a' /var/lib/my-app"
                  )).splitlines()
                  owner, group = owner.strip(), group.strip()
                  for permissions in [dataset_permissions, state_permissions]:
                      assert permissions.strip() == f"{owner} {group} 700"
                  write_data = (
                      "printf 'dataset data' > /p1/my-app/data && "
                      "printf 'persistent state' > /var/lib/my-app/state"
                  )
                  boot_id, machine_id = machine.succeed(remote(
                      "su -s /bin/sh my-app -c " + shlex.quote(write_data) + " && "
                      "touch /root/ephemeral-root-test && "
                      "cat /proc/sys/kernel/random/boot_id && cat /etc/machine-id"
                  )).splitlines()
                  boot_id, machine_id = boot_id.strip(), machine_id.strip()
                  assert boot_id and machine_id

              with subtest("reboot into a blank root while retaining application files and ownership"):
                  machine.succeed(remote("reboot"), timeout=120)
                  machine.wait_until_succeeds(remote(
                      "test \"$(cat /proc/sys/kernel/random/boot_id)\" != " + shlex.quote(boot_id)
                      + " && systemctl is-active my-app.service"
                  ), timeout=900)
                  # Remove only the final stat newline so file contents stay exact.
                  (
                      dataset_data, state_data, persisted_state,
                      reboot_owner, reboot_group, reboot_machine_id,
                      dataset_ownership, state_ownership,
                  ) = machine.succeed(remote(
                      "test ! -e /root/ephemeral-root-test && "
                      "cat /p1/my-app/data && printf '\\n' && "
                      "cat /var/lib/my-app/state && printf '\\n' && "
                      "cat /persist/var/lib/my-app/state && printf '\\n' && "
                      "id -u my-app && id -g my-app && cat /etc/machine-id && "
                      "stat -c '%u %g' /p1/my-app/data && "
                      "stat -c '%u %g' /var/lib/my-app/state"
                  )).removesuffix("\n").split("\n")
                  assert dataset_data == "dataset data"
                  assert state_data == "persistent state"
                  assert persisted_state == "persistent state"
                  assert reboot_owner.strip() == owner
                  assert reboot_group.strip() == group
                  assert reboot_machine_id.strip() == machine_id
                  for ownership in [dataset_ownership, state_ownership]:
                      assert ownership.strip() == f"{owner} {group}"
                  reboot_generation = machine.succeed(remote(
                      "readlink -f /run/current-system && "
                      "readlink -f /nix/var/nix/profiles/system && sync"
                  ), timeout=120).splitlines()
                  assert reboot_generation == [deployed_system, deployed_profile], reboot_generation

              with subtest("stop the verified deployed guest before exporting its disks"):
                  machine.succeed(shell + "idr process stop vm-test-machine", timeout=120)
                  stopped = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and (.[0].is_running | not)'"
                  )
                  machine.wait_until_succeeds(
                      shell + "bash -o pipefail -c " + shlex.quote(stopped), timeout=120,
                  )
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

          with subtest("export the verified deployed predecessor for rollback consumers"):
              # Consumers overlay these read-only disks; the archive carries only
              # source and the host key needed to access the installed machine.
              machine.succeed(
                  "mkdir -p ${archiveDirectory}/images && "
                  'cp --reflink=auto --sparse=always /root/project/.data/'
                  '$(cat /etc/machine-id)/test-machine/qemu/*.qcow2 ${archiveDirectory}/images/',
                  timeout=600,
              )
              machine.succeed(
                  "find /root/project/.data -mindepth 1 -maxdepth 1 "
                  "! -name machine-host-key -exec rm -rf {} +"
              )
              machine.succeed(
                  "tar -C /root --exclude=project/.git --exclude=project/.direnv "
                  "--sparse --sort=name --mtime=@0 --owner=1000 --group=1000 "
                  "--numeric-owner -c project > ${archiveDirectory}/project.tar",
                  timeout=600,
              )
              state = {
                  "current_system": deployed_system,
                  "system_profile": deployed_profile,
                  "owner": owner,
                  "group": group,
                  "machine_id": machine_id,
                  "dataset_data": dataset_data,
                  "state_data": state_data,
              }
              machine.succeed("printf '%s\\n' " + shlex.quote(json.dumps(state))
                  + " > ${archiveDirectory}/deployed-state.json")
        '';
      });
    };
  };
}

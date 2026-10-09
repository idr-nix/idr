top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
    networkPrefix = "fd42:1234:5678";
  in {
    checks = {
      local-vm-network-prefix = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        inherit (pkgs.stdenv.hostPlatform) isDarwin;
        originalPrefix = top.self.nixosConfigurations."example-${system}".config.idr.qemu.networkPrefix;
        readinessTimeout =
          if isDarwin
          then 3600
          else 1800;
        pollInterval =
          if isDarwin
          then "5"
          else "1";
      in {
        imports = [
          (lib.modules.importApply ./local-vm-fixture.nix {inherit top project system;})
        ];

        idr.test.direnv.offline = true;
        name = "local-vm-network-prefix";
        globalTimeout = lib.mkForce ((
            if isDarwin
            then 90
            else 45
          )
          * 60);
        defaults = {pkgs, ...}: {
          idr.qemu.networkPrefix = lib.mkForce networkPrefix;
          # Reach the archived guest until its custom-prefix generation is installed.
          systemd.services.idr-test-original-prefix = {
            description = "Provide the original bridge address during the prefix migration";
            wantedBy = ["multi-user.target"];
            after = ["systemd-networkd.service"];
            path = [pkgs.iproute2 pkgs.gnugrep];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStop = "${pkgs.iproute2}/bin/ip -6 address del ${originalPrefix}::1/48 dev idr0";
            };
            script = ''
              until ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6; do
                sleep 1
              done
              ip -6 address add ${originalPrefix}::1/48 dev idr0
            '';
          };
          systemd.services.idr-test-vm-logs = {
            description = "Forward VM output before and after changing the network prefix";
            wantedBy = ["multi-user.target"];
            serviceConfig.ExecStart = "${pkgs.coreutils}/bin/tail -n +1 -F /tmp/network-prefix-original.log /tmp/network-prefix-custom.log";
          };
        };

        testScript = ''
          import ipaddress
          import shlex

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)
          machine.wait_for_unit("idr-test-original-prefix.service")
          machine.wait_until_succeeds("ip -6 address show dev idr0 to ${originalPrefix}::1/128 | grep -q inet6")
          machine.wait_until_succeeds("ip -6 route show dev idr0 exact ${originalPrefix}::/48 | grep -q .")

          shell = "cd /root/project && direnv exec . "
          machine.succeed("cd /root/project && direnv allow")
          started = False
          log_files = []

          def start_vm(log_file):
              machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
              machine.succeed(shell + "bash -c " + shlex.quote(
                  "nohup idr process logs -f vm-test-machine > " + shlex.quote(log_file)
                  + " 2>&1 </dev/null & echo $! > " + shlex.quote(log_file + ".pid")
              ), timeout=120)
              log_files.append(log_file)
              readiness = (
                  "idr process get vm-test-machine -o json | "
                  "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
              )
              machine.succeed(
                  shell + "bash -o pipefail -c " + shlex.quote("until " + readiness + "; do sleep ${pollInterval}; done"),
                  timeout=${toString readinessTimeout},
              )

          def ssh_settings():
              machine.succeed(shell + "bash -ec " + shlex.quote(
                  "ssh -G vm-test-machine > /tmp/network-prefix-ssh"
              ), timeout=120)
              return dict(line.split(" ", 1) for line in machine.succeed("cat /tmp/network-prefix-ssh").splitlines())

          try:
              with subtest("start the existing images with their original network prefix"):
                  started = True
                  machine.succeed(shell + "idr -D", timeout=600)
                  start_vm("/tmp/network-prefix-original.log")
                  original_address = ipaddress.IPv6Address(ssh_settings()["hostname"])
                  assert original_address in ipaddress.IPv6Network("${originalPrefix}::/48"), original_address
                  original_boot = machine.succeed(
                      shell + "ssh vm-test-machine cat /proc/sys/kernel/random/boot_id", timeout=120,
                  ).strip()
                  assert original_boot

              with subtest("deploy the custom prefix for the next boot through the original address"):
                  edit = '/networking.hostName =/a\\      idr.qemu.networkPrefix = "${networkPrefix}";'
                  configuration = "nix/machine/test-machine/configuration.nix"
                  machine.succeed("cd /root/project && sed -i " + shlex.quote(edit) + " " + configuration + " && git add " + configuration)
                  # Keep the alias's SSH identity while its generated destination changes.
                  machine.succeed(
                      shell + "deploy -s --boot --ssh-opts "
                      + shlex.quote("-o HostName=" + str(original_address))
                      + " .#vm-test-machine -- -L",
                      timeout=900,
                  )

              with subtest("remove the original host prefix and restart the VM with refreshed runner settings"):
                  # Flush the deployed boot configuration before Process Compose stops QEMU.
                  machine.succeed(
                      shell + "ssh -o " + shlex.quote("HostName=" + str(original_address))
                      + " vm-test-machine poweroff",
                      timeout=120,
                  )
                  stopped = (
                      "idr process get vm-test-machine -o json | "
                      "jq -e 'length == 1 and (.[0].is_running | not)'"
                  )
                  machine.succeed(
                      shell + "bash -o pipefail -c " + shlex.quote("until " + stopped + "; do sleep ${pollInterval}; done"),
                      timeout=180,
                  )
                  machine.succeed(shell + "idr down", timeout=120)
                  started = False
                  machine.succeed("systemctl stop idr-test-original-prefix.service", timeout=120)
                  machine.wait_until_succeeds("ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6")
                  machine.wait_until_succeeds("ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q .")
                  machine.wait_until_succeeds(
                      'test -z "$(ip -6 address show dev idr0 to ${originalPrefix}::1/128)" && '
                      'test -z "$(ip -6 route show dev idr0 exact ${originalPrefix}::/48)"'
                  )
                  started = True
                  machine.succeed(shell + "idr -D", timeout=600)
                  start_vm("/tmp/network-prefix-custom.log")
                  current_boot = machine.succeed(
                      shell + "ssh vm-test-machine cat /proc/sys/kernel/random/boot_id", timeout=120,
                  ).strip()
                  assert current_boot and current_boot != original_boot, current_boot

              with subtest("the generated SSH alias reaches the VM through the custom prefix"):
                  address = ipaddress.IPv6Address(ssh_settings()["hostname"])
                  assert address in ipaddress.IPv6Network("${networkPrefix}::/48"), address
                  hostname = machine.succeed(
                      shell + "ssh vm-test-machine hostname",
                      timeout=120,
                  ).strip()
                  assert hostname == "test-machine"
                  machine.succeed("ping -6 -c 1 -W 5 " + str(address))

              with subtest("the VM can reach its host bridge address"):
                  machine.succeed(shell + "ssh vm-test-machine ping -6 -c 1 -W 5 ${networkPrefix}::1", timeout=120)
                  assert not machine.succeed("ip -6 address show dev idr0 to ${originalPrefix}::1/128").strip()
          finally:
              try:
                  if started:
                      machine.succeed(shell + "idr down", timeout=120)
              finally:
                  for log_file in log_files:
                      machine.execute("kill $(cat " + shlex.quote(log_file + ".pid") + ")")
                      machine.copy_from_machine(log_file)
        '';
      });
    };
  };
}

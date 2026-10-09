top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
    hostPkgs = pkgs;
    projectDisk =
      hostPkgs.runCommand "idr-host-network-project.ext4" {
        nativeBuildInputs = [hostPkgs.coreutils hostPkgs.e2fsprogs];
      } ''
        # Populate the filesystem directly from the archive, preserving UID/GID 1000.
        # Leave space for Git, direnv, and writes to the cached VM images.
        size_mib=$(( ($(stat -c %s ${project}/project.tar) + 1048575) / 1048576 + 2048 ))
        truncate -s "''${size_mib}M" "$out"
        mkfs.ext4 -q -F -m 0 -L idr-project \
          -E root_owner=1000:1000,lazy_itable_init=0,lazy_journal_init=0 \
          -d ${project}/project.tar "$out"
      '';
    mkCheck = selected: let
      name = "local-vm-host-network" + lib.optionalString selected "-helper";
      logFile = "/tmp/${name}.log";
    in
      pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (pkgs.stdenv.hostPlatform) isLinux;
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        example = top.self.nixosConfigurations."example-${system}".config;
        networkPrefix = example.idr.qemu.networkPrefix;
      in {
        imports = with top.self.modules.nixosTest; [base operator];

        idr.test.direnv.offline = true;
        inherit name;
        globalTimeout = 40 * 60;
        requiredFeatures.kvm = isLinux;
        idr.test.storePaths = [top.self.packages.${system}.default];

        nodes.machine = {pkgs, ...}: {
          virtualisation = {
            memorySize = lib.mkDefault 12288;
            diskSize = 32768;
            msize = 1048576;
            qemu.options = lib.mkAfter [
              "-cpu host"
              ''-smp "$(if [ "''${NIX_BUILD_CORES:-0}" -gt 0 ]; then printf '%s' "$NIX_BUILD_CORES"; else ${lib.getExe' hostPkgs.coreutils "nproc"}; fi)"''
            ];
            qemu.drives = [
              {
                name = "idr-project";
                file = toString projectDisk;
                driveExtraOpts = {
                  format = "raw";
                  snapshot = "on";
                };
                deviceExtraOpts.serial = "idr-project";
              }
            ];
            writableStoreUseTmpfs = lib.mkIf (!isLinux) (lib.mkForce false);
            fileSystems."/home/operator" = {
              device = "/dev/disk/by-id/virtio-idr-project";
              fsType = "ext4";
            };
          };
          boot.kernelModules = lib.optionals (!isLinux) ["tun"];
          networking.useDHCP = lib.mkIf (!isLinux) false;
          swapDevices = lib.mkIf (!isLinux) (lib.mkVMOverride [
            {
              device = "/var/lib/idr-test.swap";
              size = 4096;
            }
          ]);
          users.users.operator.extraGroups = ["wheel"] ++ lib.optional isLinux "kvm";
          security.sudo.wheelNeedsPassword = false;
          security.wrappers.idr-selected-bridge-helper = {
            setuid = true;
            owner = "root";
            group = "root";
            source = "${pkgs.qemu}/libexec/qemu-bridge-helper";
          };
          environment = {
            systemPackages = [pkgs.jq];
            etc."qemu/bridge.conf".text = "allow idr0";
          };
          programs.ssh.extraConfig = ''
            Host vm-*
              StrictHostKeyChecking accept-new
              BatchMode yes
              ConnectTimeout 10
          '';

          systemd.services.idr-test-vm-logs = {
            description = "Forward local VM output into the test journal";
            wantedBy = ["multi-user.target"];
            serviceConfig.ExecStart = "${pkgs.coreutils}/bin/tail -n +1 -F ${logFile}";
          };

          # Configure this case independently of the sudo fallback. The service
          # changes only the running host; it writes no network configuration.
          systemd.services.idr-test-network = lib.mkIf selected {
            description = "Prepare the bridge for the selected privileged helper";
            wantedBy = ["multi-user.target"];
            before = ["idr-project-fixture.service"];
            path = [pkgs.iproute2];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ip link add name idr0 type bridge
              ip -6 address replace ${networkPrefix}::1/48 dev idr0
              ip link set dev idr0 up
              ip -6 route replace ${networkPrefix}::/48 dev idr0 metric 256
            '';
          };

          systemd.services.idr-project-fixture = {
            description = "Prepare the mounted project and VM images for an unprivileged operator";
            wantedBy = ["multi-user.target"];
            after = ["systemd-tmpfiles-setup.service"];
            unitConfig.RequiresMountsFor = "/home/operator";
            path = [pkgs.coreutils pkgs.gitMinimal];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "operator";
              Group = "operator";
              WorkingDirectory = "/home/operator";
            };
            script = ''
              image_cache="project/.data/$(cat /etc/machine-id)/test-machine"
              mkdir -p "$image_cache"
              mv project/.data/images "$image_cache/qemu"
              git -C project init -q
              git -C project add -A
              printf 'Project fixture ready\n'
            '';
          };
        };

        testScript = ''
          import shlex
          import time

          selected = ${
            if selected
            then "True"
            else "False"
          }

          def operator(script):
              environment = ${builtins.toJSON (
            if selected
            then "env IDR_QEMU_BRIDGE_HELPER=/run/wrappers/bin/idr-selected-bridge-helper "
            else ""
          )}
              command = "cd project && direnv exec . " + environment + "bash -euo pipefail -c " + shlex.quote(script)
              return "su - operator -c " + shlex.quote(command)

          running_ready = (
              "timeout --kill-after=5s 30 idr process get vm-test-machine -o json | "
              "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"' >/dev/null"
          )
          daemon_stopped = (
              "if timeout --kill-after=5s 30 idr process get vm-test-machine -o json; "
              "then exit 1; else status=$?; fi; "
              'test "$status" -lt 124'
          )
          guest_stopped = "if pgrep -u operator qemu-system-; then exit 1; else test $? -eq 1; fi"

          def scenario():
              log_file = ${builtins.toJSON logFile}
              daemon_started = False
              log_started = False
              deadline = time.monotonic() + 2100

              def remaining(timeout):
                  available = deadline - time.monotonic()
                  assert available > 0, "host-network scenario exceeded its 2100 second deadline"
                  return min(timeout, available)

              def succeed(script, timeout):
                  return machine.succeed(operator(script), timeout=remaining(timeout))

              def dump_failure():
                  for command, timeout in (
                      (operator("timeout --kill-after=5s 30 idr process get vm-test-machine -o json"), 45),
                      ("if test -f " + shlex.quote(log_file) + "; then head -n 200 " + shlex.quote(log_file) + "; tail -n 80 " + shlex.quote(log_file) + "; fi", 30),
                      ("ip -6 address show dev idr0; ip -6 route show; pgrep -a -u operator qemu-system-", 30),
                  ):
                      try:
                          print(machine.execute(command, timeout=timeout))
                      except Exception as error:
                          print("Could not collect host-network diagnostics:", error)

              try:
                  daemon_started = True
                  succeed("timeout --kill-after=10s 600 idr -D", 610)
                  succeed("timeout --kill-after=10s 120 idr process start vm-test-machine", 130)
                  log_started = True
                  succeed(
                      "nohup timeout --kill-after=10s 2100 idr process logs -f vm-test-machine > "
                      + shlex.quote(log_file) + " 2>&1 </dev/null & echo $! > " + shlex.quote(log_file + ".pid"),
                      120,
                  )
                  machine.wait_until_succeeds(operator(running_ready), timeout=remaining(900))
                  assert succeed("timeout --kill-after=10s 120 ssh vm-test-machine hostname", 130).strip() == "test-machine"
                  machine.succeed("ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6", timeout=remaining(120))
                  machine.succeed("ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q .", timeout=remaining(120))
                  if selected:
                      succeed("pgrep -a -u operator qemu-system- | grep -F 'bridge,id=idr-local,br=idr0,helper=/run/wrappers/bin/idr-selected-bridge-helper'", 120)
                  else:
                      machine.succeed("grep -F 'using sudo to set up the idr0 network' " + shlex.quote(log_file), timeout=remaining(120))
                      machine.fail("test -e /etc/systemd/network/40-idr0.netdev", timeout=remaining(120))
                      machine.fail("test -e /etc/systemd/network/40-idr0.network", timeout=remaining(120))
                  succeed("timeout --kill-after=10s 120 idr down", 130)
                  machine.wait_until_succeeds(operator(daemon_stopped), timeout=remaining(60))
                  machine.wait_until_succeeds(guest_stopped, timeout=remaining(60))
                  daemon_started = False
              except Exception:
                  dump_failure()
                  raise
              finally:
                  try:
                      if daemon_started:
                          machine.succeed(operator("timeout --kill-after=10s 120 idr down"), timeout=130)
                          machine.wait_until_succeeds(operator(daemon_stopped), timeout=60)
                          machine.wait_until_succeeds(guest_stopped, timeout=60)
                  except Exception:
                      dump_failure()
                      raise
                  finally:
                      if log_started:
                          machine.execute(
                              "if test -f " + shlex.quote(log_file + ".pid") + "; then kill $(cat "
                              + shlex.quote(log_file + ".pid") + ") || true; fi",
                              timeout=30,
                          )
                          machine.wait_until_succeeds(
                              "if pgrep -u operator -f 'idr process logs -f vm-test-machine'; then exit 1; else test $? -eq 1; fi",
                              timeout=30,
                          )

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=1200)
          ${lib.optionalString (!isLinux) ''machine.wait_for_unit("swap.target")''}
          machine.succeed("su - operator -c " + shlex.quote("cd project && direnv allow"))
          if selected:
              machine.wait_for_unit("idr-test-network.service", timeout=120)
              machine.succeed("ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6", timeout=120)
              machine.succeed("ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q .", timeout=120)
          else:
              machine.fail("ip link show idr0", timeout=120)
              machine.fail("test -e /etc/systemd/network/40-idr0.netdev", timeout=120)
              machine.fail("test -e /etc/systemd/network/40-idr0.network", timeout=120)
          with subtest(${builtins.toJSON (
            if selected
            then "the operator boots and reaches guest SSH through the selected privileged helper"
            else "the operator boots and reaches guest SSH using the sudo network fallback"
          )}):
              scenario()
        '';
      });
  in {
    checks = {
      local-vm-host-network = mkCheck false;
      local-vm-host-network-helper = mkCheck true;
    };
  };
}

top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
  in {
    checks = {
      local-vm-host-network = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (pkgs.stdenv.hostPlatform) isLinux;
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        example = top.self.nixosConfigurations."example-${system}".config;
        networkPrefix = example.idr.qemu.networkPrefix;
        swapDevices = lib.escapeShellArgs (map (swap: swap.realDevice) example.swapDevices);
        projectDirectory =
          if isLinux
          then toString project
          else "/run/idr-project-archive";
      in {
        imports = with top.self.modules.nixosTest; [nix nix-store operator];

        name = "local-vm-host-network";
        globalTimeout = 40 * 60;
        requiredFeatures.kvm = isLinux;
        idr.test.storePaths = [top.self.packages.${system}.default];

        nodes.machine = {pkgs, ...}: {
          virtualisation = {
            memorySize =
              if isLinux
              then 12288
              else 6144;
            cores = 4;
            diskSize = 32768;
            # The fixture includes several GiB of images served over 9p.
            msize = 1048576;
            qemu.options = ["-cpu host"];
            writableStoreUseTmpfs = lib.mkIf (!isLinux) (lib.mkForce false);
            sharedDirectories = lib.optionalAttrs (!isLinux) {
              project-archive = {
                source = toString project;
                target = projectDirectory;
                securityModel = "none";
              };
            };
            fileSystems = lib.optionalAttrs (!isLinux) {
              ${projectDirectory}.options = ["ro"];
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
          nix.settings = lib.mkIf (!isLinux) {
            cores = 2;
            max-jobs = 2;
            eval-cores = lib.mkForce 2;
          };
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
            serviceConfig.ExecStart = "${pkgs.coreutils}/bin/tail -n +1 -F /tmp/host-network-bootstrap.log /tmp/host-network-selected.log";
          };

          systemd.services.idr-project-fixture = {
            description = "Restore the project and VM images for an unprivileged operator";
            wantedBy = ["multi-user.target"];
            after = ["systemd-tmpfiles-setup.service"];
            path = [pkgs.coreutils pkgs.gnutar pkgs.gitMinimal];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "operator";
              Group = "operator";
              WorkingDirectory = "/home/operator";
            };
            script = ''
              printf 'Restoring project archive: %s bytes\n' "$(stat -c %s ${projectDirectory}/project.tar)"
              df -h .
              tar --checkpoint=8192 --checkpoint-action=echo -xf ${projectDirectory}/project.tar
              printf 'Project archive restored\n'
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

          def operator(script, selected=False):
              environment = "env IDR_QEMU_EXTRA_OPTIONS_JSON='[\"-smp\",\"2\"]' "
              if selected:
                  environment += "IDR_QEMU_BRIDGE_HELPER=/run/wrappers/bin/idr-selected-bridge-helper "
              command = "cd project && " + environment + "nix --offline develop -c bash -euo pipefail -c " + shlex.quote(script)
              return "su - operator -c " + shlex.quote(command)

          readiness = (
              "idr process get vm-test-machine -o json | "
              "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"' >/dev/null"
          )
          wait_ready = shlex.quote("until " + readiness + "; do sleep 1; done")
          wait_stopped = shlex.quote("while idr process get vm-test-machine -o json >/dev/null 2>&1; do sleep 1; done")
          guest_health = shlex.quote(r"""
              set -eu
              for device in ${swapDevices}; do
                  unit=$(systemd-escape --path --suffix=swap "$device")
                  systemctl is-active "$unit"
                  udevadm info --query=property --name "$device"
              done
              swapon --show
              systemctl show idr-disk-keys.service -p Result -p CPUUsageNSec -p MemoryPeak \
                  -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic
              journalctl -b --no-pager -u 'mkswap-*' -u idr-disk-keys.service
          """)

          def scenario(selected=False):
              log_file = "/tmp/host-network-selected.log" if selected else "/tmp/host-network-bootstrap.log"
              # Enter the devshell once so polls do not compete with guest boot.
              script = r"""
                  daemon_started=0
                  log_pid=
                  phase_start=$SECONDS
                  phase() {
                      printf 'host-network phase %s: %ss\n' "$1" "$((SECONDS - phase_start))"
                      phase_start=$SECONDS
                  }
                  cleanup() {
                      result=$?
                      trap - EXIT
                      if test "$daemon_started" = 1; then
                          if ! timeout --kill-after=10s 120 idr down; then
                              if test "$result" = 0; then result=1; fi
                          fi
                      fi
                      if test -n "$log_pid"; then
                          kill "$log_pid" 2>/dev/null || true
                      fi
                      exit "$result"
                  }
                  trap cleanup EXIT
                  daemon_started=1
                  timeout --kill-after=10s 600 idr -D
                  phase daemon-start
                  timeout --kill-after=10s 120 idr process start vm-test-machine
                  phase process-start
              """
              script += "nohup timeout --kill-after=10s 2100 idr process logs -f vm-test-machine > " + shlex.quote(log_file) + " 2>&1 </dev/null &\nlog_pid=$!\n"
              script += "timeout --kill-after=10s 900 bash -euo pipefail -c " + wait_ready + "\nphase readiness\n"
              script += r"""
                  hostname=$(timeout --kill-after=10s 120 ssh -n vm-test-machine hostname)
                  test "$hostname" = test-machine
                  phase ssh-hostname
              """
              script += "timeout --kill-after=10s 120 ssh -n vm-test-machine " + guest_health + "\nphase guest-health\n"
              if selected:
                  script += r"""
                      pgrep -a qemu-system- | grep -F 'helper=/run/wrappers/bin/idr-selected-bridge-helper'
                      timeout --kill-after=10s 120 ssh -n vm-test-machine ping -6 -c 1 -W 5 ${networkPrefix}::1
                      phase selected-helper-ping
                      test ! -e /etc/systemd/network/40-idr0.netdev
                      test ! -e /etc/systemd/network/40-idr0.network
                  """
              else:
                  script += r"""
                      ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6
                      ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q .
                      grep -F 'using sudo to set up the idr0 network' /tmp/host-network-bootstrap.log
                  """
              script += "timeout --kill-after=10s 120 idr down\ndaemon_started=0\nphase daemon-stop\n"
              script += "timeout --kill-after=10s 60 bash -euo pipefail -c " + wait_stopped + "\nphase stopped\n"
              print(machine.succeed(operator(script, selected), timeout=2100))

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=1200)
          ${
            if isLinux
            then ''machine.succeed("test -c /dev/kvm")''
            else ''
              machine.wait_for_unit("swap.target")
              machine.succeed("swapon --noheadings --show=NAME | grep -Fx /var/lib/idr-test.swap")
              machine.succeed("test -c /dev/net/tun")
            ''
          }
          machine.fail("ip link show idr0")
          try:
              with subtest("a normal user starts a VM without a preconfigured bridge"):
                  scenario()

              with subtest("select a different privileged bridge helper before starting Process Compose"):
                  scenario(selected=True)

              with subtest("the fallback did not write persistent host network configuration"):
                  machine.fail("test -e /etc/systemd/network/40-idr0.netdev")
                  machine.fail("test -e /etc/systemd/network/40-idr0.network")
          except Exception:
              for log_file in ("/tmp/host-network-bootstrap.log", "/tmp/host-network-selected.log"):
                  print(machine.execute("if test -f " + log_file + "; then head -n 200 " + log_file + "; tail -n 80 " + log_file + "; fi"))
              raise
        '';
      });
    };
  };
}

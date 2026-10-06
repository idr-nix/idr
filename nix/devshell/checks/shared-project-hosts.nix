top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    identity = mode: {pkgs, ...}: {
      systemd.services.idr-test-host-identity = {
        description = "Model a host with ${mode} /etc/machine-id";
        wantedBy = ["multi-user.target"];
        requires = ["dbus.service"];
        after = ["dbus.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          # D-Bus needs an ID during startup; keep its established identity while
          # presenting the documented fallback condition to subsequent shells.
          ${pkgs.systemd}/bin/busctl --system list >/dev/null
          rm -f /etc/machine-id
          ${lib.optionalString (mode == "empty") "touch /etc/machine-id"}
        '';
      };
    };
  in {
    checks = {
      shared-project-hosts = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (pkgs.stdenv.hostPlatform) isLinux;
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        clientDefaults = {
          programs.ssh.systemd-ssh-proxy.enable = false;
          environment.etc."ssh/ssh_config".mode = "0644";
        };
        # Reuse the Nix and operator setup without the test driver's node options.
        nestedDefaults =
          (lib.evalModules {
            modules = [
              {options.defaults = lib.mkOption {type = lib.types.deferredModule;};}
              top.self.modules.nixosTest.nix
              top.self.modules.nixosTest.operator
              {defaults = clientDefaults;}
            ];
          }).config.defaults;
        hosts = {
          alpha = {pkgs, ...}: {
            systemd.services.idr-project-fixture = {
              description = "Restore one project checkout shared by all test hosts";
              wantedBy = ["multi-user.target"];
              after = ["systemd-tmpfiles-setup.service"];
              path = [pkgs.coreutils pkgs.gnutar pkgs.gitMinimal pkgs.util-linux];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                tar -C /home/operator/project --strip-components=1 -xf ${project}/project.tar
                chown -R operator:operator /home/operator/project
                runuser -u operator -- git -C /home/operator/project init -q
                runuser -u operator -- git -C /home/operator/project add -A
              '';
            };
          };
          beta = {};
          emptyid = identity "empty";
          missingid = identity "missing";
        };
      in {
        imports = with top.self.modules.nixosTest; [nix nix-store operator];

        name = "shared-project-hosts";
        globalTimeout = 20 * 60;
        idr.test.storePaths = [top.self.packages.${system}.default];

        defaults = clientDefaults;

        containerDefaults = {
          # This source is created by the test driver inside its build sandbox.
          virtualisation.systemd-nspawn.options = [
            "--bind=/tmp/idr-shared-project:/home/operator/project"
          ];
        };

        containers = lib.optionalAttrs isLinux hosts;
        nodes = lib.optionalAttrs (!isLinux) {
          machine = {
            # Keep the shared filesystem and its Unix sockets inside Linux.
            # One outer VM also needs only one copy of the large store image.
            networking.useDHCP = false;
            virtualisation = {
              memorySize = 6144;
              cores = 4;
              diskSize = 8 * 1024;
              writableStoreUseTmpfs = lib.mkForce false;
            };
            nix.settings.eval-cores = lib.mkForce 2;
            systemd.tmpfiles.rules = ["d /home/operator/project 0755 operator operator -"];
            containers =
              lib.mapAttrs (_name: definition: {
                autoStart = false;
                bindMounts."/home/operator/project" = {
                  hostPath = "/home/operator/project";
                  isReadOnly = false;
                };
                config = {
                  imports = [nestedDefaults definition];
                  nixpkgs.pkgs = config.node.pkgs;
                  system.stateVersion = "26.05";
                  nix.settings.eval-cores = lib.mkForce 2;
                };
              })
              hosts;
          };
        };

        testScript = ''
          import json
          import pathlib
          import shlex

          ${lib.optionalString (!isLinux) ''
            class ContainerHost:
                def __init__(self, name):
                    self.name = name

                def command(self, command):
                    return "nixos-container run " + self.name + " -- sh -c " + shlex.quote(command)

                def start(self):
                    machine.succeed("nixos-container start " + self.name)

                def wait_for_unit(self, unit):
                    machine.wait_until_succeeds(self.command("systemctl is-active " + shlex.quote(unit)))

                def succeed(self, command, timeout=600):
                    return machine.succeed(self.command(command), timeout=timeout)

                def fail(self, command):
                    return machine.fail(self.command(command))

            machine.start()
            machine.wait_for_unit("multi-user.target")
            alpha, beta, emptyid, missingid = [
                ContainerHost(name) for name in ("alpha", "beta", "emptyid", "missingid")
            ]
          ''}

          def operator(host, command):
              return host.succeed("su - operator -c " + shlex.quote("cd project && " + command), timeout=600)

          def state(host):
              command = (
                  'printf "%s\\n" "$PRJ_ROOT" "$PRJ_DATA_DIR" "$PC_SOCKET_PATH" "$SSH_OPTS" > /tmp/host-environment; '
                  'ssh -G vm-test-machine > /tmp/host-ssh; '
                  'idr -D; '
                  "trap 'idr down' ERR; "
                  'test -S "$PC_SOCKET_PATH"; '
                  'idr process get vm-test-machine -o json > /tmp/host-process; '
                  'trap - ERR'
              )
              operator(host, "nix --offline develop -c bash -ec " + shlex.quote(command))
              started.append(host)
              root, data, socket, ssh_options = host.succeed("cat /tmp/host-environment").splitlines()
              options = shlex.split(ssh_options)
              ssh_config = options[options.index("-F") + 1]
              settings = dict(line.split(" ", 1) for line in host.succeed("cat /tmp/host-ssh").splitlines())
              return {
                  "root": root,
                  "data": data,
                  "socket": socket,
                  "ssh_config": ssh_config,
                  "known_hosts": settings["userknownhostsfile"],
                  "process": json.loads(host.succeed("cat /tmp/host-process")),
              }

          ${lib.optionalString isLinux ''pathlib.Path("/tmp/idr-shared-project").mkdir()''}
          alpha.start()
          alpha.wait_for_unit("idr-project-fixture.service")
          for host in (beta, emptyid, missingid):
              host.start()
              host.wait_for_unit("multi-user.target")
          emptyid.wait_for_unit("idr-test-host-identity.service")
          missingid.wait_for_unit("idr-test-host-identity.service")

          with subtest("all hosts see the same mounted project checkout"):
              operator(alpha, "printf shared-checkout > shared-mount-proof")
              for host in (beta, emptyid, missingid):
                  assert operator(host, "cat shared-mount-proof") == "shared-checkout"

          hosts = (alpha, beta, emptyid, missingid)
          started = []
          try:
              with subtest("host identities separate state and Process Compose daemons"):
                  identifiers = [host.succeed("cat /etc/machine-id").strip() for host in (alpha, beta)]
                  assert identifiers[0] and identifiers[1] and identifiers[0] != identifiers[1], identifiers
                  assert emptyid.succeed("cat /etc/machine-id") == ""
                  missingid.fail("test -e /etc/machine-id")
                  identifiers += [host.succeed("hostname").strip() for host in (emptyid, missingid)]
                  # The checkout stays unchanged: capture each host's environment,
                  # start its real daemon, and query it in the same shell.
                  states = [state(host) for host in hosts]
                  for identifier, current in zip(identifiers, states):
                      assert current["root"] == "/home/operator/project", current
                      assert current["data"] == "/home/operator/project/.data", current
                      assert pathlib.PurePosixPath(current["ssh_config"]).is_relative_to(
                          pathlib.PurePosixPath(current["data"]) / identifier
                      ), current
                      result = current["process"]
                      assert len(result) == 1 and not result[0]["is_running"], result
                  for key in ("socket", "ssh_config", "known_hosts"):
                      assert len({current[key] for current in states}) == len(hosts), (key, states)

              with subtest("stopping one host leaves every other host's daemon accessible"):
                  operator(alpha, "nix --offline develop -c idr down")
                  started.remove(alpha)
                  # A fresh entry on each remaining host verifies isolation after
                  # alpha's shutdown, then stops that host's daemon.
                  for host in tuple(started):
                      operator(host, "nix --offline develop -c bash -ec " + shlex.quote(
                          "idr process get vm-test-machine -o json; idr down"
                      ))
                      started.remove(host)
          finally:
              for host in started:
                  operator(host, "nix --offline develop -c idr down")
        '';
      });
    };
  };
}

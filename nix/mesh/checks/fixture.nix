{
  top,
  leaseTTLSeconds ? 12,
}: {
  config,
  hostPkgs,
  lib,
  pkgs,
  ...
}: let
  prefix = "fdb4:cb46:0ef1";
  # alpha runs a one-member etcd cluster with the etcd module's public test
  # certificates. Its RBAC controller manages each machine's user and role,
  # derived with meshRbac as on a real RBAC host. The passwords in
  # fixtures/etcd-passwords.enc.json are public-test-<user>. beta passes its
  # password as a runtime secret instead, so alpha sets that user's password.
  etcdFixtures = ../../devshell/checks/fixtures/etcd;
  rbac = configs: let
    derived = top.idr-lib.meshRbac "main" (lib.mapAttrs (_: config: {inherit config;}) configs);
  in
    lib.recursiveUpdate derived {
      users = lib.optionalAttrs (derived.users ? mesh-beta) {mesh-beta.password = secret "etcd-password-mesh-beta";};
    };
  machines = config.nodes;
  instances = {
    alpha = {
      id = "222222222222";
      address = "192.168.1.1";
      peer = "beta";
    };
    beta = {
      id = "333333333333";
      address = "192.168.1.2";
      peer = "alpha";
    };
  };
  # These credentials protect only public test data.
  psk = "Ju9LWIXXFv+NqeYQSeqy88vS/0sz0zQi3+jXbJQuugc=";
  secret = name: {
    path = "/run/mesh-test-secrets/${name}";
    group = "root";
    reloadTarget = "mesh-test-secrets.target";
    restartTarget = "mesh-test-secrets.target";
  };
  mkService = {
    id,
    peers,
    body,
  }: {
    imports = [top.self.modules.service.mesh];
    idr.mesh = {
      inherit id;
      peers = lib.genAttrs peers (_: {psk = secret "psk";});
    };
    process.argv = [
      (lib.getExe pkgs.busybox)
      "httpd"
      "-f"
      "-p"
      "[::]:8080"
      "-h"
      (pkgs.writeTextDir "index.html" body)
    ];
    systemd.service = {
      wantedBy = lib.mkOverride 900 [];
      serviceConfig.DynamicUser = true;
    };
  };
  script = ''
    import json

    members = {"alpha": alpha, "beta": beta}
    instances = json.loads('${builtins.toJSON instances}')
    initial_psk = "${psk}"
    mesh_prefix = "${prefix}"
    scope = f"/idr/mesh/{mesh_prefix}/services/"
    # Every machine reaches etcd through its local proxy, as the agents do.
    etcd = "etcdctl --endpoints=http://main.etcd.internal:1023 --command-timeout=3s "
    # The test observes etcd over alpha's loopback, which outages leave alone.
    admin = "etcdctl --endpoints=https://[::1]:2379 --insecure-skip-tls-verify --command-timeout=3s --user=root:public-test-root "

    # The agent marks each workload once its instance is registered and addressed.
    def wait_registered(machine, service="app"):
        machine.wait_until_succeeds(f"test -e /run/idr-mesh-agent/registered/{service}", timeout=90)

    # The agent counts each completed address collection, including its re-applies.
    def collections(machine):
        return machine.succeed("cat /run/idr-mesh-addresses/collections").strip()

    def setup_mesh():
        start_all()
        alpha.wait_for_unit("idr-etcd-rbac-main.service")
        alpha.fail(etcd + f"get {scope} --prefix")
        for machine in members.values():
            machine.succeed("systemctl start --no-block app.service")
        for machine in members.values():
            machine.wait_for_unit("app.service")
            wait_registered(machine)

    def registrations():
        return json.loads(alpha.succeed(admin + f"get {scope} --prefix --write-out=json"))

    def inside(command, service="app"):
        return f'nsenter --target "$(systemctl show {service}.service --property=MainPID --value)" --mount --net -- ' + command

    def request(peer, service="app"):
        target = instances[peer]["id"] if peer in instances else peer
        host = f"[{target}]" if ":" in target else f"{target}.mesh"
        return inside(
            "curl --noproxy '*' --fail --silent --show-error --connect-timeout 2 --max-time 4 "
            + f"http://{host}:8080/",
            service,
        )

    # Idle once netd holds the desired state of the agent's latest snapshot.
    def wait_mesh_idle(machine, service="app"):
        machine.wait_until_succeeds(
            f"discovered=$(jq -e .state.revision /run/idr-mesh-agent/peers/{service}.json) && "
            f"applied=$(jq -e .state.revision /run/idr-mesh-apply/{service}/desired.json) && "
            'test "$discovered" = "$applied" && '
            f"test $(systemctl show idr-mesh-apply@{service}.service --property=ActiveState --value) != activating",
            timeout=60,
        )
  '';
in {
  imports = with top.self.modules.nixosTest; [disk-storage kvm-clock];
  _module.args.meshFixture = {inherit prefix instances psk secret mkService script leaseTTLSeconds rbac;};
  globalTimeout = lib.mkDefault (15 * 60);
  requiredFeatures.kvm = hostPkgs.stdenv.hostPlatform.isLinux;

  nodeDefaults.virtualisation = {
    memorySize = 1024;
    cores = 2;
    msize = 262144;
  };

  defaults = {config, ...}: {
    imports = with top.self.modules.nixos; [mesh sops secrets systemd etcd];
    _module.args.inputs = top.inputs;
    # This identity is deliberately public and protects only synthetic test data.
    sops.age = {
      keyFile = "/var/lib/sops-nix/key.txt";
      sshKeyPaths = [];
    };
    sops.gnupg.sshKeyPaths = [];
    sops.useSystemdActivation = true;
    # sops-nix defines the unit only while there are secrets.
    systemd.services.sops-install-secrets = lib.mkIf (config.sops.secrets != {}) {
      after = ["systemd-tmpfiles-setup.service"];
    };
    networking.useDHCP = false;
    networking.nftables.enable = true;
    environment.systemPackages = [pkgs.curl pkgs.etcd.deps.etcdctl pkgs.jq pkgs.nftables pkgs.wireguard-tools];
    systemd.tmpfiles.rules = [
      "d /var/lib/sops-nix 0700 root root -"
      "C /var/lib/sops-nix/key.txt 0400 root root - ${../../devshell/checks/fixtures/runtime-secrets/key.txt}"
      # Secret references follow idr's secrets: mode 0440, readable by their group.
      "d /run/mesh-test-secrets 0750 root root -"
      "C /run/mesh-test-secrets/psk 0400 root root - ${pkgs.writeText "mesh-test-psk" psk}"
      "C /run/mesh-test-secrets/etcd-password-mesh-beta 0440 root root - ${pkgs.writeText "mesh-test-etcd-password" "public-test-mesh-beta"}"
    ];
    systemd.targets.mesh-test-secrets = {
      requires = ["systemd-tmpfiles-setup.service"];
      after = ["systemd-tmpfiles-setup.service"];
    };
    idr.mesh = {
      enable = true;
      etcd.main = {
        ipv6Prefix = prefix;
        endpoint = "http://main.etcd.internal:1023";
        inherit leaseTTLSeconds;
      };
    };
    idr.etcd.proxy.main = {
      endpoints = [
        {
          domain = "etcd-alpha.example.test";
          ip = "192.168.1.1";
        }
      ];
      caCert = etcdFixtures + "/ca.pem";
    };
  };

  nodes = lib.mkMerge [
    (lib.mapAttrs (name: instance: {
        idr.mesh.publicAddresses = [instance.address];
        idr.mesh.etcd.main =
          {username = "mesh-${name}";}
          // (
            if name == "beta"
            then {password = secret "etcd-password-mesh-beta";}
            else {
              password = {
                sopsFile = ./fixtures/etcd-passwords.enc.json;
                key = "mesh-${name}";
              };
            }
          );
        system.services.app = mkService {
          id = instance.id;
          peers = [instances.${instance.peer}.id];
          body = name;
        };
      })
      instances)
    {
      alpha = {config, ...}: {
        idr.secrets-source = lib.genAttrs ["alpha-wireguard-key" "alpha-cert" "alpha-cert-key" "root-password"] (_: {
          sopsFile = etcdFixtures + "/initial.enc.json";
          format = "json";
        });
        idr.etcd = {
          privateNetwork = {
            listenPort = 61010;
            privKey = config.idr.secrets.alpha-wireguard-key;
          };
          clusters.main = {
            instances.alpha = {
              dataDir = "/p1/etcd-alpha";
              cert = config.idr.secrets.alpha-cert;
              certKey = config.idr.secrets.alpha-cert-key;
              clusterToken = "public-mesh-test";
              publicHostname = "etcd-alpha.example.test";
              allowedIPs = ["192.168.1.0/24"];
            };
            rbac =
              {
                endpoints = [{domain = "etcd-alpha.example.test";}];
                caCert = etcdFixtures + "/ca.pem";
                rootPassword = config.idr.secrets.root-password;
              }
              // rbac machines;
          };
        };
      };
    }
  ];
}

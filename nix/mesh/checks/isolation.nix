top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    hosts = {
      alpha.address = "2001:db8:1::1";
      beta.address = "2001:db8:1::2";
    };
    probe = pkgs.writeScript "mesh-isolation-probe" ''
      #!${lib.getExe' pkgs.busybox "sh"}
      exit_code() { "$@" >/dev/null 2>&1; printf '%s' "$?"; }
      probe_socket() { exit_code ${lib.getExe' pkgs.netcat-openbsd "nc"} -U -z -w 1 "$1"; }
      interface=$(exit_code ${lib.getExe' pkgs.iproute2 "ip"} link set dev idr-mesh down)
      namespace=$(exit_code ${lib.getExe' pkgs.util-linux "unshare"} --net ${lib.getExe' pkgs.coreutils "true"})
      body=$(${lib.getExe pkgs.curl} --noproxy '*' --fail --silent --connect-timeout 2 --max-time 4 http://333333333333.mesh:8080/)
      peer=$?
      printf 'Content-Type: application/json\r\n\r\n'
      exec ${lib.getExe pkgs.jq} -nc --rawfile status /proc/self/status \
        --argjson interfaceChange "$interface" --argjson namespaceChange "$namespace" \
        --arg peerBody "$body" --argjson peerStatus "$peer" \
        --argjson nscdStatus "[$(probe_socket /run/nscd/socket),$(probe_socket /var/run/nscd/socket)]" \
        --argjson userStatus "$(exit_code ${lib.getExe' pkgs.coreutils "id"} -un)" '$ARGS.named'
    '';
    appRoot = pkgs.linkFarm "mesh-isolation-app" [
      {
        name = "index.html";
        path = pkgs.writeText "mesh-isolation-index" "alpha";
      }
      {
        name = "cgi-bin/probe";
        path = probe;
      }
    ];
    probeRoot = pkgs.writeTextDir "index.html" "reachable";
    httpd = root: port: "${lib.getExe pkgs.busybox} httpd -f -p [::]:${toString port} -h ${root}";
  in {
    checks.mesh-isolation = pkgs.testers.runNixOSTest ({meshFixture, ...}: {
      imports = [
        (lib.modules.importApply ./fixture.nix {inherit top;})
      ];
      name = "mesh-isolation";

      defaults = {
        environment.systemPackages = [pkgs.dig];
        networking.firewall.allowedTCPPorts = [8081];
        systemd.services.mesh-isolation-host-probe = {
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            ExecStart = httpd probeRoot 8081;
            DynamicUser = true;
          };
        };
      };

      nodes =
        lib.mapAttrs (name: host: {
          networking.interfaces.eth1.ipv6.addresses = [
            {
              address = host.address;
              prefixLength = 64;
            }
          ];
          networking.nftables.enable = lib.mkIf (name == "alpha") (lib.mkForce false);
          systemd.services.nscd.unitConfig.ConditionPathExists = lib.mkIf (name == "alpha") "/run/mesh-test-start-nscd";
          system.services = lib.mkIf (name == "alpha") {
            app.systemd.service.serviceConfig = {
              IPAddressDeny = ["any"];
              IPAddressAllow = ["${meshFixture.prefix}:3333:3333:3333::/96"];
            };
            app.process.argv = lib.mkForce [
              (lib.getExe pkgs.busybox)
              "httpd"
              "-f"
              "-p"
              "[::]:8080"
              "-h"
              appRoot
            ];
            isolated = meshFixture.mkService {
              id = "444444444444";
              peers = [];
              body = "isolated";
            };
          };
          systemd.services.mesh-isolation-dns-probe = lib.mkIf (name == "alpha") {
            requires = ["idr-mesh-dns-netns.service"];
            after = ["idr-mesh-dns-netns.service"];
            serviceConfig = {
              ExecStart = httpd probeRoot 8080;
              NetworkNamespacePath = "/run/netns/idr-dns";
              DynamicUser = true;
            };
          };
        })
        hosts;

      testScript =
        meshFixture.script
        + ''
          setup_mesh()
          alpha.succeed("systemctl start isolated.service mesh-isolation-dns-probe.service")
          alpha.wait_for_unit("isolated.service")
          alpha.wait_for_unit("mesh-isolation-dns-probe.service")
          profiles = json.loads(alpha.succeed("cat /etc/idr-mesh/dns.json"))["services"]
          mesh_units = ["app.service", "idr-mesh-dns.service"]

          def mesh_pids():
              return {
                  unit: alpha.succeed(f"systemctl show {unit} --property=MainPID --value").strip()
                  for unit in mesh_units
              }

          original_pids = mesh_pids()
          dns_pid = original_pids["idr-mesh-dns.service"]

          def http(address, port=8080):
              return (
                  "curl --noproxy '*' --fail --silent --show-error --connect-timeout 1 --max-time 2 "
                  + f"'http://[{address}]:{port}/'"
              )

          def namespace(name, command):
              return f"ip netns exec {name} {command}"

          def blocked(machine, command):
              status, output = machine.execute(command)
              assert status == 28, f"expected a firewall timeout, got {status}: {output}"

          def restore_dns_firewalls():
              alpha.succeed("systemctl reload idr-mesh-dns-netns.service")
              for service, profile in profiles.items():
                  alpha.succeed(namespace(f"idr-mesh-{service}", f"nft -f {profile['clientFirewall']}"))

          def check_nscd_isolation():
              result = json.loads(beta.succeed(inside(
                  "curl --noproxy '*' --fail --silent --max-time 5 "
                  + f"http://{instances['alpha']['id']}.mesh:8080/cgi-bin/probe",
              )))
              assert result["peerStatus"] == 0 and result["peerBody"].strip() == "beta"
              assert all(status != 0 for status in result["nscdStatus"])
              assert result["userStatus"] == 0
              for socket in ["/run/nscd/socket", "/var/run/nscd/socket"]:
                  alpha.fail(f"nsenter --target {dns_pid} --mount --net -- ${lib.getExe' pkgs.netcat-openbsd "nc"} -U -z -w 1 {socket}")
              return result

          with subtest("DNS views expose only declared peers over both UDP and TCP"):
              for transport in ["", "+tcp"]:
                  query = f"dig +time=1 +tries=1 {transport}"
                  alpha.wait_until_succeeds(inside(query + f" {instances['beta']['id']}.mesh AAAA +short | grep '^fd'"))
                  for service in ["app", "isolated"]:
                      assert "status: NOERROR" in alpha.succeed(inside(query + " mesh SOA", service))
                  hidden = alpha.succeed(inside(query + f" {instances['beta']['id']}.mesh AAAA", "isolated"))
                  assert "status: NXDOMAIN" in hidden and "ANSWER: 0" in hidden
              alpha.fail(inside(http("2001:db8:1::1", 8081)))
              alpha.wait_until_succeeds(request("beta"))

          with subtest("workloads and CoreDNS cannot change the network isolation"):
              result = check_nscd_isolation()
              process_statuses = [result["status"], alpha.succeed(f"cat /proc/{dns_pid}/status")]
              forbidden = (1 << 12) | (1 << 13) | (1 << 21)  # NET_ADMIN, NET_RAW, SYS_ADMIN
              for process_status in process_statuses:
                  status = dict(line.split(":", 1) for line in process_status.splitlines())
                  assert all(int(uid) != 0 for uid in status["Uid"].split())
                  assert int(status["CapEff"], 16) & forbidden == 0
                  assert int(status["CapBnd"], 16) & forbidden == 0
                  assert status["NoNewPrivs"].strip() == "1"
              assert result["interfaceChange"] != 0 and result["namespaceChange"] != 0

          with subtest("starting and restarting host nscd preserves running mesh DNS isolation"):
              alpha.fail("systemctl is-active --quiet nscd.service")
              alpha.succeed("test -d /run/nscd", "test ! -S /run/nscd/socket", "touch /run/mesh-test-start-nscd")
              for action in ["start", "restart", "stop", "start"]:
                  alpha.succeed(f"systemctl {action} nscd.service")
                  socket = "${lib.getExe' pkgs.netcat-openbsd "nc"} -U -z -w 1 /run/nscd/socket"
                  if action == "stop":
                      alpha.fail(socket)
                  else:
                      alpha.succeed(socket)
                  check_nscd_isolation()
                  assert mesh_pids() == original_pids

          with subtest("each end of the DNS link independently rejects non-DNS connections"):
              client = profiles["isolated"]
              to_dns = namespace("idr-mesh-isolated", http(client["serverAddress"]))
              from_dns = namespace("idr-dns", http(client["clientAddress"]) + " --local-port 53")
              assert alpha.succeed(namespace("idr-mesh-isolated", http(client["clientAddress"]))).strip() == "isolated"
              alpha.succeed("systemctl stop idr-mesh-dns.service")
              try:
                  alpha.succeed(namespace("idr-dns", "nft delete table inet idr_mesh_dns"))
                  assert alpha.succeed(namespace("idr-dns", http(client["serverAddress"]))).strip() == "reachable"
                  blocked(alpha, to_dns)
                  blocked(alpha, from_dns)
                  restore_dns_firewalls()
                  alpha.succeed(namespace("idr-mesh-isolated", "nft delete table inet idr_mesh_dns"))
                  blocked(alpha, to_dns)
                  blocked(alpha, from_dns)
              finally:
                  restore_dns_firewalls()
                  alpha.succeed("systemctl start idr-mesh-dns.service")
              alpha.wait_until_succeeds(request("beta"))

          with subtest("the DNS namespace cannot forward traffic between services"):
              for source, target in [("app", "isolated"), ("isolated", "app")]:
                  alpha.succeed(
                      f"ip -n idr-mesh-{source} -6 route add {profiles[target]['clientAddress']}/128 "
                      + f"via {profiles[source]['serverAddress']} dev idr-dns",
                      namespace(f"idr-mesh-{source}", "nft delete table inet idr_mesh_dns"),
                  )
              alpha.succeed(namespace("idr-dns", "sysctl -w net.ipv6.conf.all.forwarding=1"))
              cross_service = namespace("idr-mesh-app", http(profiles["isolated"]["clientAddress"]))
              try:
                  blocked(alpha, cross_service)
                  alpha.succeed(namespace("idr-dns", "nft delete table inet idr_mesh_dns"))
                  assert alpha.succeed(cross_service).strip() == "isolated"
              finally:
                  restore_dns_firewalls()
              blocked(alpha, cross_service)
              alpha.wait_until_succeeds(request("beta"))
        '';
    });
  };
}

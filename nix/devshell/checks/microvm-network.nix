top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    networkLib = import ../../microvm/network-lib.nix {inherit lib;};
    scapy = pkgs.python3.withPackages (ps: [ps.scapy]);
    guests = {
      a = {
        enable = true;
        network = {
          enable = true;
          tapName = "tap-a";
          macAddress = "02:00:00:00:00:0a";
          ipv4Address = "10.1.0.2";
          ipv6Address = networkLib.ipv6Address "fd54:0fb7:359f" "ee170c3c" "0f3d0421d0e8";
        };
      };
      b = {
        enable = true;
        machine.config.services.openssh = {
          enable = true;
          ports = [2222];
        };
        network = {
          enable = true;
          tapName = "tap-b";
          macAddress = "02:00:00:00:00:0b";
          ipv4Address = "10.1.0.3";
          ipv6Address = networkLib.ipv6Address "fd54:0fb7:359f" "ee170c3c" "0f3d0421d0e9";
        };
      };
    };
    guest = name: vlan: {
      virtualisation.interfaces.eth1 = {inherit vlan;};
      services.openssh.enable = true;
      services.openssh.ports = guests.${name}.machine.config.services.openssh.ports or [22];
      systemd.services.systemd-networkd.preStart = ''
        ${pkgs.iproute2}/bin/ip link set eth1 address ${guests.${name}.network.macAddress}
      '';
      systemd.network.networks."10-guest" = {
        matchConfig.Name = "eth1";
        networkConfig = {
          DHCP = "yes";
          IPv6AcceptRA = true;
          IPv6PrivacyExtensions = false;
          IPv6LinkLocalAddressGenerationMode = "eui64";
          MulticastDNS = false;
          LLMNR = false;
        };
        dhcpV4Config.ClientIdentifier = "mac";
        dhcpV6Config = {
          DUIDType = "link-layer";
          WithoutRA = "solicit";
        };
        ipv6AcceptRAConfig.UseAutonomousPrefix = false;
        linkConfig.RequiredForOnline = false;
      };
    };
  in {
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      microvm-network = pkgs.testers.runNixOSTest {
        name = "microvm-network";
        globalTimeout = 5 * 60;
        requiredFeatures.kvm = false;

        defaults = {
          networking = {
            useDHCP = false;
            useNetworkd = true;
            useHostResolvConf = false;
            firewall.allowedTCPPorts = [8080];
          };
          services.resolved.enable = true;
          environment.systemPackages = [pkgs.curl pkgs.openssh pkgs.nftables];
          systemd.services.http = {
            wantedBy = ["multi-user.target"];
            serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080 --bind :: --directory ${pkgs.writeTextDir "index.html" "reachable"}";
          };
        };

        containers = {
          a = guest "a" 1;
          b = guest "b" 2;
          lan = {
            virtualisation.interfaces.eth1.vlan = 4;
            systemd.network.networks."10-lan" = {
              matchConfig.Name = "eth1";
              networkConfig.DHCP = "ipv4";
              linkConfig.RequiredForOnline = false;
            };
          };
          outside = {
            virtualisation.interfaces.eth1.vlan = 3;
            networking.interfaces.eth1 = {
              ipv4.addresses = [
                {
                  address = "198.51.100.2";
                  prefixLength = 24;
                }
              ];
              ipv6.addresses = [
                {
                  address = "2001:db8:1::2";
                  prefixLength = 64;
                }
              ];
            };
            services.dnsmasq = {
              enable = true;
              settings = {
                bind-interfaces = true;
                interface = "eth1";
                no-resolv = true;
                address = ["/outside.test/198.51.100.2" "/outside.test/2001:db8:1::2"];
              };
            };
            networking.firewall.allowedUDPPorts = [53];
          };
          host = {extendModules, ...}: {
            imports = [(lib.modules.importApply ../../microvm/network.nix top)];
            options.idr.microvm.vms = lib.mkOption {
              type = lib.types.attrsOf lib.types.raw;
              default = {};
            };
            config = {
              idr.microvm.vms = guests;
              networking.hostId = "ee170c3c";
              virtualisation.interfaces = {
                tap-a.vlan = 1;
                tap-b.vlan = 2;
                wan.vlan = 3;
                lan.vlan = 4;
              };
              networking.interfaces.lan.ipv4.addresses = [
                {
                  address = "192.0.2.1";
                  prefixLength = 24;
                }
              ];
              networking.firewall.interfaces.lan.allowedUDPPorts = [53 67];
              services.resolved.enable = lib.mkForce false;
              services.dnsmasq.resolveLocalQueries = true;
              networking.interfaces.wan = {
                ipv4.addresses = [
                  {
                    address = "198.51.100.1";
                    prefixLength = 24;
                  }
                ];
                ipv6.addresses = [
                  {
                    address = "2001:db8:1::1";
                    prefixLength = 64;
                  }
                ];
              };
              services.dnsmasq.settings = {
                no-resolv = true;
                server = ["198.51.100.2"];
                interface = ["lan"];
                dhcp-range = ["192.0.2.10,192.0.2.20,255.255.255.0,1h"];
                # A pre-existing authoritative LAN pool must not loosen the
                # MicroVM server's static DHCPv6 reservation checks.
                dhcp-authoritative = true;
              };
              # Nspawn cannot switch NixOS specialisations. Apply only the
              # actual tables evaluated with each documented firewall option.
              environment.etc = lib.mapAttrs' (name: settings: let
                tables = (extendModules {modules = [settings];}).config.networking.nftables.tables;
              in
                lib.nameValuePair "microvm-firewall/${name}" {
                  text = ''
                    flush ruleset
                    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_: table:
                      lib.optionalString table.enable ''
                        table ${table.family} ${table.name} {
                          ${table.content}
                        }
                      '')
                    tables)}
                  '';
                }) {
                default = {};
                peer.idr.microvm.network.firewall = {
                  extraForwardRules = ''
                    ip saddr 10.1.0.2 ip daddr 10.1.0.3 tcp dport 8080 accept
                    ip6 saddr ${guests.a.network.ipv6Address} ip6 daddr ${guests.b.network.ipv6Address} tcp dport 8080 accept
                  '';
                };
                no-ssh.idr.microvm.network.firewall.allowHostSSH = false;
                disabled.idr.microvm.network.firewall.enable = false;
                renamed-tap.idr.microvm.vms = lib.mkForce (lib.recursiveUpdate guests {a.network.tapName = "tap-a-next";});
                renamed-bridge.idr.microvm.network.bridgeName = "idr-next";
                no-network.idr.microvm.vms = lib.mkForce (lib.mapAttrs (_: vm: lib.recursiveUpdate vm {network.enable = false;}) guests);
              };
            };
          };
        };

        testScript = ''
          import ipaddress
          import json
          import shlex

          guests = json.loads('${builtins.toJSON (lib.mapAttrs (_: vm: vm.network) guests)}')

          def http(address):
              return "curl --noproxy '*' -gfsS --connect-timeout 1 --max-time 2 http://" + (
                  "[" + address + "]" if ":" in address else address
              ) + ":8080/"

          def policy(name):
              host.succeed("nft -f /etc/microvm-firewall/" + name)

          def guard_drops(chain, table="bridge idr-microvm-ports"):
              rules = json.loads(host.succeed("nft -j list table " + table))
              return sum(
                  expr["counter"]["packets"]
                  for item in rules["nftables"] if item.get("rule", {}).get("chain") == chain
                  for expr in item["rule"]["expr"] if "counter" in expr
                  and any("drop" in verdict for verdict in item["rule"]["expr"])
                  # Normal MLD reports hit the final IPv6 drop. Count only
                  # matching guard rules when checking forged IPv6 packets.
                  and (chain != "ipv6-a" or len(item["rule"]["expr"]) > 2)
              )

          start_all()
          host.wait_for_unit("dnsmasq.service")
          outside.wait_for_unit("dnsmasq.service")
          for machine in [host, a, b, outside]:
              machine.wait_for_unit("http.service")

          with subtest("existing host DNS and LAN DHCP keep their own settings"):
              host.wait_until_succeeds("getent ahostsv4 outside.test | grep -F 198.51.100.2", timeout=30)
              lan.wait_until_succeeds("ip -4 address show eth1 | grep -E 'inet 192.0.2.[0-9]+/24'", timeout=30)
              lan.succeed("ip -4 route show default | grep -F 'via 192.0.2.1'")
              lan.succeed("resolvectl dns eth1 | grep -F 192.0.2.1")
              lan.fail("ip -4 route show | grep -F 10.1.0.1")

          with subtest("DHCP assigns only the declared IPv4 and composed IPv6 addresses"):
              for name, machine in [("a", a), ("b", b)]:
                  expected = guests[name]
                  for key in ["ipv4Address", "ipv6Address"]:
                      address = str(ipaddress.ip_address(expected[key]))
                      machine.wait_until_succeeds("ip address show eth1 | grep -F " + shlex.quote(address), timeout=40)
                  assert machine.succeed(http("outside.test")).strip() == "reachable"
                  # DHCPv6 can complete before the first router advertisement.
                  try:
                      machine.wait_until_succeeds("ip -6 route show default | grep -q default", timeout=30)
                      machine.wait_until_succeeds(http("2001:db8:1::2"), timeout=30)
                  except Exception:
                      for endpoint in [host, machine, outside]:
                          print(endpoint.succeed("ip -6 address; ip -6 route; ip -6 neighbor"))
                      print(host.succeed("nft list ruleset"))
                      raise

          with subtest("host SSH is allowed while guests cannot initiate host or peer connections"):
              for address in [guests["a"]["ipv4Address"], guests["a"]["ipv6Address"]]:
                  host.succeed("ssh-keyscan -T 2 -t ed25519 " + address)
                  host.fail(http(address))
              for address in [guests["b"]["ipv4Address"], guests["b"]["ipv6Address"]]:
                  host.succeed("ssh-keyscan -T 2 -p 2222 -t ed25519 " + address)
              for address in ["10.1.0.1", "fd54:fb7:359f:ee17:c3c::1", guests["b"]["ipv4Address"], guests["b"]["ipv6Address"]]:
                  a.fail(http(address))
              # A malicious guest can ignore the DHCP route and send directly
              # to a peer's MAC; this must not bypass the host firewall.
              for family, address in [("-4", guests["b"]["ipv4Address"]), ("-6", guests["b"]["ipv6Address"])]:
                  a.succeed(f"ip {family} route add {address} dev eth1")
                  a.succeed(f"ip {family} neigh replace {address} lladdr {guests['b']['macAddress']} nud permanent dev eth1")
                  a.fail(http(address))
                  a.succeed(f"ip {family} route del {address} dev eth1")

          with subtest("firewall options allow a peer exception, disable SSH, or disable isolation"):
              policy("peer")
              for address in [guests["b"]["ipv4Address"], guests["b"]["ipv6Address"]]:
                  a.succeed(http(address))
              policy("no-ssh")
              host.fail("ssh-keyscan -T 2 -t ed25519 " + guests["a"]["ipv4Address"])
              host.fail("ssh-keyscan -T 2 -p 2222 -t ed25519 " + guests["b"]["ipv4Address"])
              policy("disabled")
              host.fail("nft list table bridge idr-microvm-ports")
              host.fail("nft list table inet idr-microvm-network")
              a.succeed(http("10.1.0.1"))
              a.succeed(http(guests["b"]["ipv4Address"]))
              policy("default")

          with subtest("DHCP payload identities cannot disable a peer's static lease"):
              # A malicious client can spoof BOOTP chaddr independently of
              # its Ethernet source, including inside fragmented DHCP packets.
              for source in ["0.0.0.0", guests["a"]["ipv4Address"]]:
                  for fragmented in [False, True]:
                      guard = ("ipv4-a", "bridge idr-microvm-ports") if source == "0.0.0.0" and fragmented else ("dhcp4", "inet idr-microvm-network")
                      before = guard_drops(*guard)
                      script = "\n".join([
                          "from scapy.all import *",
                          "packet = IP(src=" + repr(source) + ",dst='255.255.255.255')/UDP(sport=68,dport=67)/BOOTP(chaddr=bytes.fromhex('02000000000b'))/DHCP(options=[('message-type','decline'),('requested_addr','10.1.0.3'),('server_id','10.1.0.1'),'end'])",
                          "packets = fragment(packet, fragsize=24)" if fragmented else "packets = [packet]",
                          "sendp([Ether(src='02:00:00:00:00:0a',dst='ff:ff:ff:ff:ff:ff')/p for p in packets],iface='eth1',verbose=False)",
                      ])
                      a.succeed("${scapy}/bin/python3 -c " + shlex.quote(script))
                      assert guard_drops(*guard) > before, (source, fragmented)
              host.fail("journalctl -u dnsmasq --no-pager | grep -F 'disabling DHCP static address'")
              b.succeed("networkctl renew eth1")
              b.succeed(http("198.51.100.2"))

          with subtest("guests cannot act as DHCPv6 relays"):
              before = guard_drops("prerouting", "inet idr-microvm-network")
              script = "from scapy.all import *; sendp(Ether(src='02:00:00:00:00:0a',dst='33:33:00:01:00:02')/IPv6(src='fe80::ff:fe00:a',dst='ff02::1:2')/UDP(sport=546,dport=547)/DHCP6_RelayForward(linkaddr='fd54:fb7:359f:ee17:c3c::1',peeraddr='fe80::ff:fe00:b')/DHCP6OptClientLinkLayerAddr(clladdr='02:00:00:00:00:0b')/DHCP6OptRelayMsg(message=DHCP6_Solicit()),iface='eth1',verbose=False)"
              a.succeed("${scapy}/bin/python3 -c " + shlex.quote(script))
              assert guard_drops("prerouting", "inet idr-microvm-network") > before

          with subtest("DHCPv6 rebind cannot acquire a peer's reservation"):
              script = "from scapy.all import *; sendp(Ether(src='02:00:00:00:00:0a',dst='33:33:00:01:00:02')/IPv6(src='fe80::ff:fe00:a',dst='ff02::1:2')/UDP(sport=546,dport=547)/DHCP6_Rebind(trid=0x494452)/DHCP6OptClientId(duid=DUID_LL(lladdr='02:00:00:00:00:0a'))/DHCP6OptIA_NA(iaid=909,T1=0,T2=0,ianaopts=[DHCP6OptIAAddress(addr='fd54:fb7:359f:ee17:c3c:f3d:421:d0e9')]),iface='eth1',verbose=False)"
              a.succeed("${scapy}/bin/python3 -c " + shlex.quote(script))
              leases = host.succeed("cat /var/lib/dnsmasq/dnsmasq.leases")
              assert not any("fd54:fb7:359f:ee17:c3c:f3d:421:d0e9" in line and "00:03:00:01:02:00:00:00:00:0a" in line for line in leases.splitlines())

          with subtest("DHCPv6 lease maintenance belongs to the configured guest"):
              leases = host.succeed("cat /var/lib/dnsmasq/dnsmasq.leases").splitlines()
              address = str(ipaddress.ip_address(guests["b"]["ipv6Address"]))
              peer = next(line.split() for line in leases if address in line)
              server_hex = next(line.split()[1] for line in leases if line.startswith("duid ")).replace(":", "")

              def lease_message(machine, message, mac, source):
                  script = (
                      "from scapy.all import *; sendp(Ether(src=" + repr(mac) + ",dst='33:33:00:01:00:02')/IPv6(src=" + repr(source) + ",dst='ff02::1:2')/UDP(sport=546,dport=547)/" + message + "(trid=0x494452)"
                      "/DHCP6OptClientId(duid=DUID_LL(lladdr='02:00:00:00:00:0b'))/DHCP6OptServerId(duid=Raw(bytes.fromhex(" + repr(server_hex) + ")))"
                      "/DHCP6OptIA_NA(iaid=" + peer[1] + ",T1=0,T2=0,ianaopts=[DHCP6OptIAAddress(addr=" + repr(address) + ")]),iface='eth1',verbose=False)"
                  )
                  machine.succeed("${scapy}/bin/python3 -c " + shlex.quote(script))

              # DUID and IAID are client identifiers, not authentication secrets.
              for message in ["DHCP6_Renew", "DHCP6_Release", "DHCP6_Decline"]:
                  lease_message(a, message, guests["a"]["macAddress"], "fe80::ff:fe00:a")
                  assert " ".join(peer) in host.succeed("cat /var/lib/dnsmasq/dnsmasq.leases"), message

              # A client with an old reservation needs a reply invalidating it,
              # rather than endless retransmission while its lease is infinite.
              for stale in ["fd54:fb7:359f:ee17:c3c:f3d:421:d0ea", "fd54:fb7:359f:aaaa:bbbb::2"]:
                  for message in ["DHCP6_Renew", "DHCP6_Rebind"]:
                      server_option = "/DHCP6OptServerId(duid=Raw(bytes.fromhex(" + repr(server_hex) + ")))" if message == "DHCP6_Renew" else ""
                      script = (
                          # Match multicast requests and unicast replies by transaction ID.
                          "from scapy.all import *; conf.checkIPsrc=False; packet=Ether(src='02:00:00:00:00:0b',dst='33:33:00:01:00:02')/IPv6(src='fe80::ff:fe00:b',dst='ff02::1:2')/UDP(sport=546,dport=547)/" + message + "(trid=0x494453)"
                          "/DHCP6OptClientId(duid=DUID_LL(lladdr='02:00:00:00:00:0b'))" + server_option +
                          "/DHCP6OptIA_NA(iaid=" + peer[1] + ",T1=0,T2=0,ianaopts=[DHCP6OptIAAddress(addr=" + repr(stale) + ")]); "
                          "reply=srp1(packet,iface='eth1',timeout=3,verbose=False); assert reply is not None; "
                          "lease=reply[DHCP6OptIAAddress]; assert lease.addr == " + repr(stale) + "; assert lease.preflft == 0 and lease.validlft == 0"
                      )
                      b.succeed("${scapy}/bin/python3 -c " + shlex.quote(script))

              # The owner can still renew and release its own reservation.
              lease_message(b, "DHCP6_Renew", guests["b"]["macAddress"], "fe80::ff:fe00:b")
              host.succeed("journalctl -u dnsmasq --no-pager | grep -F DHCPRENEW | grep -F 00:03:00:01:02:00:00:00:00:0b")
              lease_message(b, "DHCP6_Release", guests["b"]["macAddress"], "fe80::ff:fe00:b")
              assert address not in host.succeed("cat /var/lib/dnsmasq/dnsmasq.leases")
              b.succeed("networkctl reconfigure eth1")
              host.wait_until_succeeds("grep -F " + address + " /var/lib/dnsmasq/dnsmasq.leases", timeout=40)
              b.wait_until_succeeds(http("2001:db8:1::2"), timeout=30)

          with subtest("retired interfaces stay blocked until the VM uses its new network"):
              for name in ["idr-microvm", "tap-a", "tap-b"]:
                  # Confirm networkd assigned the persistent kernel group.
                  group = json.loads(host.succeed("ip -j link show " + name))[0]["group"]
                  assert str(group) == "4801618", (name, group)
              for name in ["renamed-tap", "renamed-bridge", "no-network"]:
                  policy(name)
                  before = guard_drops("prerouting")
                  a.fail(http("198.51.100.2"))
                  a.fail(http("2001:db8:1::2"))
                  a.fail(http("10.1.0.1"))
                  assert guard_drops("prerouting") > before, name
                  policy("default")
                  a.succeed(http("198.51.100.2"))

          with subtest("the guest port rejects MAC, address, neighbor and VLAN spoofing"):
              # Send frames directly through the guest-facing port, bypassing
              # the guest kernel's normal source and neighbor validation.
              mac = guests["a"]["macAddress"]
              host_mac = host.succeed("cat /sys/class/net/idr-microvm/address").strip()
              a.succeed("ip link set eth1 promisc on")
              packets = [
                  ("guest-a", "Ether(src='02:00:00:ff:ff:ff',dst=dst)/IP(src='10.1.0.2',dst='198.51.100.2')/UDP(dport=5555)"),
                  ("ipv4-a", "Ether(src=src,dst=dst)/IP(src='10.1.0.3',dst='198.51.100.2')/UDP(dport=5555)"),
                  ("ipv6-a", "Ether(src=src,dst=dst)/IPv6(src='fd54:fb7:359f:ee17:c3c:f3d:421:d0e9',dst='2001:db8:1::2')/UDP(dport=5555)"),
                  ("arp-a", "Ether(src=src,dst=dst)/ARP(op=2,hwsrc=src,psrc='10.1.0.1',hwdst=dst,pdst='10.1.0.2')"),
                  ("arp-a", "Ether(src=src,dst=dst)/ARP(op=2,hwsrc='02:00:00:ff:ff:ff',psrc='10.1.0.2',hwdst=dst,pdst='10.1.0.1')"),
                  ("ipv6-a", "Ether(src=src,dst=dst)/IPv6(src='fe80::ff:fe00:a',dst='ff02::1',hlim=255)/ICMPv6ND_NA(tgt='fd54:fb7:359f:ee17:c3c::1',R=1,S=0,O=1)/ICMPv6NDOptDstLLAddr(lladdr=src)"),
                  ("ipv6-a", "Ether(src=src,dst=dst)/IPv6(src='fe80::ff:fe00:a',dst='ff02::1',hlim=255)/ICMPv6ND_RA()"),
                  ("guest-a", "Ether(src=src,dst=dst)/Dot1Q(vlan=10)/IP(src='10.1.0.2',dst='198.51.100.2')/UDP(dport=5555)"),
              ]
              for chain, packet in packets:
                  before = guard_drops(chain)
                  script = "from scapy.all import *; src=" + repr(mac) + "; dst=" + repr(host_mac) + "; sendp(" + packet + ",iface='eth1',verbose=False)"
                  a.succeed("${scapy}/bin/python3 -c " + shlex.quote(script))
                  assert guard_drops(chain) > before, packet
              a.succeed(http("outside.test"))
        '';
      };
    };
  };
}

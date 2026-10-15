top: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkOption types;
  cfg = config.idr.microvm.network;
  project = config.idr.preset.base.inputs.self.idrMicrovm.network or {};
  net = import ./network-lib.nix {inherit lib;};
  vms = lib.filterAttrs (_: vm: vm.enable && vm.network.enable) config.idr.microvm.vms;
  networks = map (vm: vm.network) (builtins.attrValues vms);
  ipv4 = net.parseIpv4Subnet cfg.ipv4Subnet;
  ipv6Subnet = net.ipv6Subnet cfg.ipv6Prefix config.networking.hostId;
  ipv6Gateway = net.ipv6Gateway cfg.ipv6Prefix config.networking.hostId;
  bridgeMAC = "02:${lib.concatStringsSep ":" (lib.genList (i: builtins.substring (i * 2) 2 (builtins.hashString "sha256" "idr-microvm/${config.networking.hostId}")) 5)}";
  bridgeLL = net.linkLocalAddress bridgeMAC;
  # Stable kernel group (ASCII "IDR"): old interfaces remain identifiable when
  # a host switch changes networking before the running VM is restarted.
  interfaceGroup = 4801618;
  tapSet = lib.concatMapStringsSep ", " (network: ''"${network.tapName}"'') networks;
  unique = values: builtins.length values == builtins.length (lib.unique values);

  portRules = name: vm: let
    network = vm.network;
    mac = lib.toLower network.macAddress;
    address4 = network.ipv4Address;
    address6 = network.ipv6Address;
    linkLocal = net.linkLocalAddress mac;
    owned6 = "{ ${address6}, ${linkLocal} }";
  in ''
    chain guest-${name} {
      ether saddr != ${mac} counter drop
      ether type arp jump arp-${name}
      ether type ip jump ipv4-${name}
      ether type ip6 jump ipv6-${name}
      counter drop
    }

    chain arp-${name} {
      arp htype != 1 counter drop
      arp ptype != ip counter drop
      arp hlen != 6 counter drop
      arp plen != 4 counter drop
      arp saddr ether != ${mac} counter drop
      arp operation request arp saddr ip 0.0.0.0 arp daddr ip ${address4} accept
      arp operation { request, reply } arp saddr ip ${address4} accept
      counter drop
    }

    chain ipv4-${name} {
      ip saddr 0.0.0.0 ip daddr { 255.255.255.255, ${ipv4.gateway} } ip frag-off & 0x3fff == 0 udp sport 68 udp dport 67 accept
      ip saddr != ${address4} counter drop
      udp sport 67 counter drop
      accept
    }

    chain ipv6-${name} {
      # DAD can use :: only for this guest's own addresses.
      ip6 saddr :: ip6 hoplimit 255 exthdr frag missing icmpv6 type nd-neighbor-solicit icmpv6 taddr ${owned6} accept
      ip6 saddr != ${owned6} counter drop
      icmpv6 type { nd-router-advert, nd-redirect } counter drop
      udp sport 547 counter drop

      # NDP target checks prevent claiming a peer's address using our own source.
      ip6 hoplimit 255 exthdr frag missing icmpv6 type nd-neighbor-advert icmpv6 taddr ${owned6} accept
      ip6 hoplimit 255 exthdr frag missing icmpv6 type nd-neighbor-solicit icmpv6 taddr { ${ipv6Gateway}, ${bridgeLL} } accept
      ip6 saddr ${linkLocal} ip6 daddr ff02::2 ip6 hoplimit 255 exthdr frag missing icmpv6 type nd-router-solicit accept
      icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } counter drop

      ip6 saddr ${linkLocal} ip6 daddr { ff02::1:2, ${bridgeLL}, ${ipv6Gateway} } exthdr frag missing udp sport 546 udp dport 547 accept
      ip6 saddr ${address6} accept
      counter drop
    }
  '';
in {
  options.idr.microvm.network = {
    bridgeName = mkOption {
      type = types.strMatching "[a-zA-Z0-9_-]{1,15}";
      default = "idr-microvm";
      description = "Private bridge for the host's MicroVMs.";
    };
    ipv4Subnet = mkOption {
      type = types.str;
      default = project.ipv4Subnet or "10.1.0.0/16";
      description = "Guest IPv4 subnet. The first usable address belongs to the host.";
    };
    ipv6Prefix = mkOption {
      type = types.strMatching "[fF][dD][0-9a-fA-F]{2}:[0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}";
      default = project.ipv6Prefix or "fd54:0fb7:359f";
      description = "ULA /48 prefix as three hexadecimal groups. Host and guest IDs provide the remaining 80 bits.";
    };
    nat = mkOption {
      type = types.bool;
      default = true;
      description = "Masquerade guest IPv4 and IPv6 traffic leaving the private network.";
    };
    firewall = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enforce guest addresses and isolate guests from the host, peers, and unsolicited inbound traffic.";
      };
      allowHostSSH = mkOption {
        type = types.bool;
        default = true;
        description = "Allow host-initiated SSH connections to guests.";
      };
      extraInputRules = mkOption {
        type = types.lines;
        default = "";
        description = "Additional nftables rules for guest-to-host traffic, before the isolation drop.";
      };
      extraForwardRules = mkOption {
        type = types.lines;
        default = "";
        description = "Additional nftables rules for routed guest traffic, before the isolation drops.";
      };
      extraOutputRules = mkOption {
        type = types.lines;
        default = "";
        description = "Additional nftables rules for host-to-guest traffic, before the isolation drop.";
      };
    };
  };

  config = lib.mkMerge [
    (mkIf (vms != {}) {
      assertions = [
        {
          assertion = config.networking.hostId != null && builtins.match "[0-9a-fA-F]{8}" config.networking.hostId != null;
          message = "idr.microvm: networking.hostId must contain eight hexadecimal digits for IPv6 addressing.";
        }
        {
          assertion = lib.all (network: network.ipv4Address != null && net.ipv4ToInt network.ipv4Address > ipv4.first + 1 && net.ipv4ToInt network.ipv4Address < ipv4.last) networks;
          message = "idr.microvm: each guest needs an IPv4 address in network.ipv4Subnet, excluding the network, host gateway, and broadcast addresses.";
        }
        {
          assertion = unique (map (network: network.ipv4Address) networks) && unique (map (network: lib.toLower network.ipv6Address) networks);
          message = "idr.microvm: guest IPv4 and IPv6 addresses must be unique on the host.";
        }
        {
          assertion = lib.all (network: !builtins.elem (lib.toLower network.ipv6Address) (map (id: net.ipv6Address cfg.ipv6Prefix config.networking.hostId id) ["000000000000" "000000000001"])) networks;
          message = "idr.microvm: guest IDs 000000000000 and 000000000001 are reserved for the IPv6 subnet and host gateway.";
        }
        {
          assertion = !builtins.elem cfg.bridgeName (map (network: network.tapName) networks);
          message = "idr.microvm: a guest TAP cannot have the private bridge's name.";
        }
        {
          assertion = config.networking.nftables.enable;
          message = "idr.microvm: private networking requires networking.nftables.enable.";
        }
      ];

      systemd.network = {
        enable = true;
        netdevs."40-idr-microvm" = {
          netdevConfig = {
            Kind = "bridge";
            Name = cfg.bridgeName;
            MACAddress = bridgeMAC;
          };
          bridgeConfig.MulticastSnooping = false;
        };
        networks =
          {
            "40-idr-microvm" = {
              matchConfig.Name = cfg.bridgeName;
              address = ["${ipv4.gateway}/${toString ipv4.prefixLength}" "${ipv6Gateway}/80"];
              networkConfig = {
                ConfigureWithoutCarrier = true;
                LinkLocalAddressing = "ipv6";
                IPv6LinkLocalAddressGenerationMode = "eui64";
                IPv6AcceptRA = false;
                IPv4Forwarding = true;
                IPv6Forwarding = true;
              };
              linkConfig = {
                RequiredForOnline = false;
                Group = interfaceGroup;
              };
              # Seed neighbors; port guards also reject forged ARP/NDP updates.
              neighbors = lib.concatMap (network:
                map (address: {
                  Address = address;
                  LinkLayerAddress = network.macAddress;
                }) [network.ipv4Address network.ipv6Address (net.linkLocalAddress network.macAddress)])
              networks;
            };
          }
          // lib.mapAttrs' (name: vm:
            lib.nameValuePair "40-idr-microvm-${name}-tap" {
              matchConfig.Name = vm.network.tapName;
              networkConfig = {
                Bridge = cfg.bridgeName;
                LinkLocalAddressing = "no";
              };
              bridgeConfig = {
                Isolated = true;
                UseBPDU = false;
              };
              linkConfig = {
                RequiredForOnline = false;
                Group = interfaceGroup;
              };
            })
          vms;
      };

      services.dnsmasq = {
        enable = true;
        # Bind maintenance of static DHCPv6 leases to the reservation selected
        # by the guest's verified MAC, including RELEASE/DECLINE with forged IDs.
        package = lib.mkDefault (pkgs.dnsmasq.overrideAttrs (old: {
          patches = (old.patches or []) ++ [./dnsmasq-static-leases.patch];
        }));
        resolveLocalQueries = lib.mkDefault false;
        settings = {
          interface = [cfg.bridgeName];
          except-interface = lib.optional (!config.services.dnsmasq.resolveLocalQueries) "lo";
          bind-dynamic = true;
          enable-ra = true;
          dhcp-range = [
            "${ipv4.gateway},static,${ipv4.netmask},infinite"
            "${ipv6Gateway},static,off-link,80,infinite"
          ];
          dhcp-host = lib.mapAttrsToList (name: vm: "${vm.network.macAddress},id:*,${vm.network.ipv4Address},[${vm.network.ipv6Address}],${name}") vms;
          dhcp-option = [
            # Dnsmasq tags requests with the receiving interface. Keep these
            # routes and DNS servers out of other DHCP pools on the host.
            "tag:${cfg.bridgeName},option:netmask,255.255.255.255"
            "tag:${cfg.bridgeName},option:classless-static-route,${ipv4.gateway}/32,0.0.0.0,0.0.0.0/0,${ipv4.gateway}"
            "tag:${cfg.bridgeName},option:router,${ipv4.gateway}"
            "tag:${cfg.bridgeName},option:dns-server,${ipv4.gateway}"
            "tag:${cfg.bridgeName},option6:dns-server,[${ipv6Gateway}]"
          ];
        };
      };

      networking.hosts = lib.mkMerge (lib.mapAttrsToList (name: vm: {
          "${vm.network.ipv4Address}" = [name];
          "${vm.network.ipv6Address}" = [name];
        })
        vms);

      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = lib.mkDefault 1;
        "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
        # Forwarding must not disable RA on the host's existing uplink.
        "net.ipv6.conf.all.accept_ra" = lib.mkDefault 2;
        "net.ipv6.conf.default.accept_ra" = lib.mkDefault 2;
      };

      networking.nftables = {
        enable = true;
        tables = {
          idr-microvm-nat = mkIf cfg.nat {
            family = "inet";
            content = ''
              chain postrouting {
                type nat hook postrouting priority srcnat; policy accept;
                iifname "${cfg.bridgeName}" oifname != "${cfg.bridgeName}" ip saddr ${cfg.ipv4Subnet} masquerade
                iifname "${cfg.bridgeName}" oifname != "${cfg.bridgeName}" ip6 saddr ${ipv6Subnet} masquerade
              }
            '';
          };
        };
      };
      networking.firewall = {
        interfaces.${cfg.bridgeName} = {
          allowedTCPPorts = [53];
          allowedUDPPorts = [53 67 547];
        };
        # The earlier chains above already enforce the complete MicroVM policy.
        # Continue through the standard firewall without undoing its exceptions.
        extraInputRules = mkIf cfg.firewall.enable ''
          iifname "${cfg.bridgeName}" accept
        '';
        extraForwardRules = mkIf cfg.firewall.enable ''
          iifname "${cfg.bridgeName}" accept
          oifname "${cfg.bridgeName}" accept
        '';
      };

      systemd.services =
        {
          dnsmasq = {
            after = ["systemd-networkd.service" "nftables.service"];
            requires = ["nftables.service"];
          };
        }
        // lib.mapAttrs' (name: _:
          lib.nameValuePair "microvm@idr-${name}" {
            after = ["nftables.service" "dnsmasq.service"];
            requires = ["nftables.service"];
            wants = ["dnsmasq.service"];
          })
        vms;
    })
    (mkIf (config.idr.microvm.vms != {} && cfg.firewall.enable) {
      networking.nftables = {
        enable = true;
        tables = {
          idr-microvm-ports = {
            family = "bridge";
            content = ''
              chain prerouting {
                type filter hook prerouting priority -300; policy accept;
                iifgroup ${toString interfaceGroup} meta ibrname != "${cfg.bridgeName}" counter drop
                ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: vm: ''iifname "${vm.network.tapName}" jump guest-${name}'') vms)}
                # Unconfigured or retired ports must not bypass source checks.
                iifgroup ${toString interfaceGroup} counter drop
                meta ibrname "${cfg.bridgeName}" counter drop
              }
              chain forward {
                type filter hook forward priority -300; policy accept;
                iifgroup ${toString interfaceGroup} counter drop
                meta ibrname "${cfg.bridgeName}" counter drop
              }
              ${lib.concatStringsSep "\n" (lib.mapAttrsToList portRules vms)}
            '';
          };
          idr-microvm-network = {
            family = "inet";
            content = ''
              chain prerouting {
                type filter hook prerouting priority raw; policy accept;
                # A TAP not yet enslaved by networkd must not bypass bridge guards.
                ${lib.optionalString (networks != []) ''iifname { ${tapSet} } counter drop''}
                # Retired bridges and detached ports keep their kernel group.
                iifgroup ${toString interfaceGroup} iifname != "${cfg.bridgeName}" counter drop
                iifname "${cfg.bridgeName}" meta nfproto ipv4 udp dport 67 jump dhcp4
                # Guests are DHCPv6 clients, never trusted relays carrying a
                # claimed peer MAC. Check after reassembly, including fragments.
                iifname "${cfg.bridgeName}" meta nfproto ipv6 udp dport 547 @th,64,8 12 counter drop
              }
              chain dhcp4 {
                # Dnsmasq identifies clients by BOOTP chaddr, not Ethernet source.
                # Validate after IP reassembly so fragments cannot bypass it.
                # chaddr starts 28 bytes into the UDP payload (8 + 28 = 36).
                ${lib.concatMapStrings (network: let
                  mac = lib.toLower network.macAddress;
                  hexMac = lib.replaceStrings [":"] [""] mac;
                in ''
                  ether saddr ${mac} @th,288,48 0x${hexMac} accept
                '')
                networks}
                counter drop
              }
              chain input {
                type filter hook input priority filter - 10; policy accept;
                iifname "${cfg.bridgeName}" jump from-guests
              }
              chain from-guests {
                ct state invalid counter drop
                ct state { established, related } accept
                udp sport 68 udp dport 67 accept
                udp sport 546 udp dport 547 accept
                udp dport 53 accept
                tcp dport 53 accept
                icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
                ${cfg.firewall.extraInputRules}
                counter drop
              }
              chain output {
                type filter hook output priority filter - 10; policy accept;
                oifname "${cfg.bridgeName}" jump to-guests
              }
              chain to-guests {
                ct state invalid counter drop
                ct state { established, related } accept
                udp sport 67 udp dport 68 accept
                udp sport 547 udp dport 546 accept
                icmpv6 type { nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
                ${lib.optionalString cfg.firewall.allowHostSSH (lib.concatMapStrings (vm: let
                ssh =
                  vm.machine.config.services.openssh or {
                    enable = true;
                    ports = [22];
                  };
                ports = lib.concatMapStringsSep ", " toString ssh.ports;
              in
                lib.optionalString (ssh.enable && ssh.ports != []) ''
                  ip daddr ${vm.network.ipv4Address} tcp dport { ${ports} } accept
                  ip6 daddr ${vm.network.ipv6Address} tcp dport { ${ports} } accept
                '') (builtins.attrValues vms))}
                ${cfg.firewall.extraOutputRules}
                counter drop
              }
              chain forward {
                type filter hook forward priority filter - 10; policy accept;
                iifname "${cfg.bridgeName}" jump guest-forward
                oifname "${cfg.bridgeName}" jump guest-forward
              }
              chain guest-forward {
                ct state invalid counter drop
                ct state { established, related } accept
                ${cfg.firewall.extraForwardRules}
                iifname "${cfg.bridgeName}" oifname != "${cfg.bridgeName}" accept
                counter drop
              }
            '';
          };
        };
      };
    })
  ];
}

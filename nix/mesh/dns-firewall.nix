{
  lib,
  pkgs,
  refusingPort,
}: services: let
  # CoreDNS forwarding to its own refusing server, over loopback.
  refusing = direction: "ip6 saddr ::1 ip6 daddr ::1 meta l4proto { tcp, udp } th ${direction} ${toString refusingPort} accept";
  request = entry: "ip6 saddr ${entry.clientAddress} ip6 daddr ${entry.serverAddress} meta l4proto { tcp, udp } th dport 53";
  reply = entry: "ip6 saddr ${entry.serverAddress} ip6 daddr ${entry.clientAddress} meta l4proto { tcp, udp } th sport 53";
  serverRules = render: lib.concatMapStringsSep "\n" render (lib.attrValues services);
  ruleset = name: owner: content:
    pkgs.writeText name ''
      add table inet idr_mesh_dns { comment "${owner}"; }
      flush table inet idr_mesh_dns
      table inet idr_mesh_dns {
        ${content}
      }
    '';
in {
  server = ruleset "idr-mesh-dns-server.nft" "idr-mesh-dns-server" ''
    chain prerouting {
      type filter hook prerouting priority raw; policy drop;
      iifname "lo" ${refusing "dport"}
      iifname "lo" ${refusing "sport"}
      ${serverRules (entry: ''iifname "${entry.interface}" ${request entry} accept'')}
    }

    chain raw_output {
      type filter hook output priority raw; policy drop;
      oifname "lo" ${refusing "dport"}
      oifname "lo" ${refusing "sport"}
      ${serverRules (entry: ''oifname "${entry.interface}" ${reply entry} accept'')}
    }

    chain input {
      type filter hook input priority filter; policy drop;
      iifname "lo" ${refusing "dport"}
      iifname "lo" ${refusing "sport"}
      ${serverRules (entry: ''iifname "${entry.interface}" ${request entry} ct direction original ct state { new, established } accept'')}
    }

    chain output {
      type filter hook output priority filter; policy drop;
      oifname "lo" ${refusing "dport"}
      oifname "lo" ${refusing "sport"}
      ${serverRules (entry: ''oifname "${entry.interface}" ${reply entry} ct direction reply ct state established accept'')}
    }

    chain forward {
      type filter hook forward priority filter; policy drop;
    }
  '';

  clients = lib.mapAttrs (name: entry:
    ruleset "idr-mesh-dns-${name}.nft" entry.alias ''
      chain prerouting {
        type filter hook prerouting priority raw; policy accept;
        iifname "idr-dns" ${reply entry} accept
        iifname "idr-dns" drop
      }

      chain raw_output {
        type filter hook output priority raw; policy accept;
        oifname "idr-dns" ${request entry} accept
        oifname "idr-dns" drop
      }

      chain input {
        type filter hook input priority filter; policy accept;
        iifname "idr-dns" ${reply entry} ct direction reply ct state established accept
        iifname "idr-dns" drop
      }

      chain output {
        type filter hook output priority filter; policy accept;
        oifname "idr-dns" ${request entry} ct direction original ct state { new, established } accept
        oifname "idr-dns" drop
      }

      chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "idr-dns" drop
        oifname "idr-dns" drop
      }
    '')
  services;
}

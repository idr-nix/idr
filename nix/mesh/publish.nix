{
  setupExe,
  meshServices,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.mesh;
  # The workload end of each link. The host ends start with idrp.
  device = "idr-publish";
  publishing =
    lib.mapAttrs (name: service: let
      hash = builtins.hashString "sha256" name;
      subnet = lib.concatStringsSep ":" (lib.genList (index: builtins.substring (index * 4) 4 hash) 4);
      # A /31 in the IPv4 /16 prefix.
      pair = lib.mod (lib.fromHexString (builtins.substring 16 4 hash)) 32768;
      ipv4 = last: "${cfg.published.ipv4Prefix}.${toString (pair / 128)}.${toString (lib.mod pair 128 * 2 + last)}";
    in {
      inherit hash;
      ports = lib.unique (map (entry: {inherit (entry) proto port;}) service.publish);
      # What the workload may open to the internet, as nftables matches.
      outbound =
        lib.optionals service.internet.enable
        (lib.concatMap allowed service.internet.allow ++ map resolver (lib.take 2 cfg.internet.nameservers));
      interface = "idrp${builtins.substring 0 11 hash}";
      alias = "idr-mesh-publish-${hash}";
      hostAddress6 = "${cfg.published.ipv6Prefix}:${subnet}:0001";
      workloadAddress6 = "${cfg.published.ipv6Prefix}:${subnet}:0002";
      hostAddress4 = ipv4 0;
      workloadAddress4 = ipv4 1;
      hostMac = "02:00:00:00:00:01";
      workloadMac = "02:00:00:00:00:02";
    })
    (lib.filterAttrs (_: service: service.publish != [] || service.internet.enable) meshServices);
  family = address:
    if lib.hasInfix ":" address
    then "ip6"
    else "ip";
  # One match per address family of the destinations.
  allowed = entry: let
    dport = "${entry.proto} dport ${ports entry.port}";
  in
    if entry.destinations == []
    then [dport]
    else
      lib.mapAttrsToList (family: addresses: "${family} daddr { ${lib.concatStringsSep ", " addresses} } ${dport}")
      (lib.groupBy family entry.destinations);
  resolver = address: "${family address} daddr ${address} meta l4proto { tcp, udp } th dport 53";
  range = port:
    if lib.isInt port
    then {
      from = port;
      to = port;
    }
    else port;
  # A port, or a range of ports, in nftables.
  ports = port:
    if lib.isInt port
    then toString port
    else "${toString port.from}-${toString port.to}";
  elements = link: lib.concatMapStringsSep ", " (entry: "${entry.proto} . ${ports entry.port}") link.ports;
  # The workload accepts new connections only to its published ports, and
  # opens new connections through the link only as its internet access
  # allows, although its default route leads there. Other connections fail at
  # once instead of timing out.
  firewall = link:
    pkgs.writeText "idr-mesh-publish-${link.hash}.nft" ''
      add table inet idr_mesh_publish { comment "${link.alias}"; }
      flush table inet idr_mesh_publish
      table inet idr_mesh_publish {
        chain input {
          type filter hook input priority filter; policy accept;
          iifname "${device}" ct state established,related accept
          ${lib.optionalString (link.ports != []) ''
        iifname "${device}" ct state new ip6 daddr ${link.workloadAddress6} meta l4proto . th dport { ${elements link} } accept
        iifname "${device}" ct state new ip daddr ${link.workloadAddress4} meta l4proto . th dport { ${elements link} } accept
      ''}
          iifname "${device}" drop
        }

        chain output {
          type filter hook output priority filter; policy accept;
          oifname "${device}" ct state established,related accept
          ${lib.concatMapStrings (match: ''
          oifname "${device}" ct state new ${match} accept
        '')
        link.outbound}
          oifname "${device}" reject
        }

        chain forward {
          type filter hook forward priority filter; policy accept;
          iifname "${device}" drop
          oifname "${device}" drop
        }
      }
    '';
  inventory = name: link:
    pkgs.writeText "idr-mesh-publish-${link.hash}.json" (builtins.toJSON {
      services.${name} = builtins.removeAttrs link ["hash" "ports" "outbound"] // {firewall = firewall link;};
    });
  # Connections to a published port of any host address go to its workload,
  # keeping their source address. Connections that a workload may open to the
  # internet leave with the host's address. Workloads cannot connect to the
  # host.
  hostRules = ''
    chain prerouting {
      type nat hook prerouting priority dstnat; policy accept;
      ${lib.concatStrings (lib.mapAttrsToList (_: link:
      lib.concatMapStrings (entry: ''
        iifname != "idrp*" fib daddr type local meta nfproto ipv6 ${entry.proto} dport ${ports entry.port} dnat ip6 to ${link.workloadAddress6}
        iifname != "idrp*" fib daddr type local meta nfproto ipv4 ${entry.proto} dport ${ports entry.port} dnat ip to ${link.workloadAddress4}
      '')
      link.ports)
    publishing)}
    }

    chain postrouting {
      type nat hook postrouting priority srcnat; policy accept;
      ${lib.concatStrings (lib.mapAttrsToList (_: link:
      lib.optionalString (link.outbound != []) ''
        ip6 saddr ${link.workloadAddress6} oifname != "idrp*" masquerade
        ip saddr ${link.workloadAddress4} oifname != "idrp*" masquerade
      '')
    publishing)}
    }

    chain input {
      type filter hook input priority filter; policy accept;
      iifname "idrp*" ct state new drop
    }
  '';
  forwardRules = lib.concatStrings (lib.mapAttrsToList (_: link:
    lib.concatMapStrings (match: ''
      iifname "${link.interface}" ${match} accept
    '')
    link.outbound)
  publishing);
  # Every workload requires its instance of the template, which finds no
  # inventory when it neither publishes ports nor has internet access. A
  # change of any workload's ports or internet access only
  # changes the template's reload trigger: the running instances reload and
  # apply their links in place, and the workloads keep running. The trigger
  # is never removed, as switching ignores a removed trigger.
  command = action: "${setupExe} publish ${action} -- %i /etc/idr-mesh/publish/%i.json /run/idr-mesh-publish/%i/state.json";
  inventories = pkgs.writeText "idr-mesh-publish.json" (builtins.toJSON (lib.mapAttrs inventory publishing));
  publishServices = {
    "idr-mesh-publish@" = {
      reloadTriggers = [inventories];
      description = "Mesh published ports and internet access for %i";
      bindsTo = ["idr-mesh-netns@%i.service"];
      after = ["idr-mesh-netns@%i.service"];
      partOf = ["idr-mesh-netns@%i.service"];
      unitConfig.StopWhenUnneeded = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = command "create-link";
        ExecReload = command "create-link";
        ExecStopPost = command "remove-link";
        RuntimeDirectory = "idr-mesh-publish/%i";
        RuntimeDirectoryMode = "0700";
        CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_SYS_ADMIN" "CAP_DAC_OVERRIDE"];
        NoNewPrivileges = true;
        UMask = "0077";
      };
    };
  };
  uniqueField = field: lib.allUnique (lib.mapAttrsToList (_: link: link.${field}) publishing);
  published = lib.concatMap (link: link.ports) (lib.attrValues publishing);
  overlap = a: b: a.proto == b.proto && (range a.port).from <= (range b.port).to && (range b.port).from <= (range a.port).to;
  disjoint = entries:
    entries
    == []
    || !(lib.any (overlap (lib.head entries)) (lib.tail entries)) && disjoint (lib.tail entries);
in {
  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.etc = lib.mapAttrs' (name: link:
        lib.nameValuePair "idr-mesh/publish/${name}.json" {source = inventory name link;})
      publishing;
      systemd.services = publishServices;
      # networkd leaves veths alone; dhcpcd would configure the host ends.
      networking.dhcpcd.denyInterfaces = ["idrp*"];
    }

    (lib.mkIf (publishing != {}) {
      assertions = [
        {
          assertion = config.networking.nftables.enable && config.networking.firewall.filterForward;
          message = "Publishing mesh ports and internet access need the nftables firewall with networking.firewall.filterForward, which the base preset enables.";
        }
        {
          assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version "6.17";
          message = "Publishing mesh ports and internet access need Linux 6.17 or later, for per-interface IPv6 forwarding.";
        }
        {
          assertion = lib.all (link: link.outbound == []) (lib.attrValues publishing) || cfg.internet.nameservers != [];
          message = "Mesh internet access needs idr.mesh.internet.nameservers, which defaults to networking.nameservers.";
        }
        {
          assertion = disjoint published;
          message = "Published mesh ports and port ranges must not overlap: each port and protocol belongs to one workload of the machine.";
        }
        {
          assertion = uniqueField "interface" && uniqueField "hostAddress6" && uniqueField "hostAddress4";
          message = "Mesh publish links must have distinct interface names and addresses.";
        }
      ];

      # Forward to the links without making the host an IPv6 router, which
      # would stop it from accepting router advertisements. The firewall only
      # forwards the published connections and those that internet access
      # allows.
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.force_forwarding" = 1;
        "net.ipv6.conf.default.force_forwarding" = 1;
      };
      networking.firewall.extraForwardRules = forwardRules;
      networking.nftables.tables.idr_mesh_publish = {
        family = "inet";
        content = hostRules;
      };
    })
  ]);
}

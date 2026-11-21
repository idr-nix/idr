{
  setupExe,
  meshServices,
}: {
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  cfg = config.idr.mesh;
  readerGroup = "idr-mesh-dns-readers";
  userNss = pkgs.linkFarm "idr-mesh-user-nss" [
    {
      name = "libnss_systemd.so.2";
      path = "${config.systemd.package}/lib/libnss_systemd.so.2";
    }
  ];
  services =
    lib.mapAttrs (name: service: let
      hash = builtins.hashString "sha256" name;
      subnet = lib.concatStringsSep ":" (lib.genList (index: builtins.substring (index * 4) 4 hash) 4);
    in {
      inherit hash;
      interface = "d${builtins.substring 0 14 hash}";
      clientAddress = "${cfg.dns.ipv6Prefix}:${subnet}:0001";
      serverAddress = "${cfg.dns.ipv6Prefix}:${subnet}:0002";
      zone = "/run/idr-mesh-dns/zones/${hash}/mesh.zone";
      clientMac = "02:00:00:00:00:01";
      serverMac = "02:00:00:00:00:02";
      alias = "idr-mesh-dns-${hash}";
    })
    meshServices;
  firewall = (import ./dns-firewall.nix {inherit lib pkgs;}) services;
  profiles = lib.mapAttrs (name: service:
    builtins.removeAttrs service ["hash"]
    // {clientFirewall = firewall.clients.${name};})
  services;
  corefile = pkgs.writeText "idr-mesh-Corefile" (
    lib.concatStrings (lib.mapAttrsToList (_: service: ''
        mesh:53 {
          bind ::
          errors
          view ${service.hash} {
            expr incidr(client_ip(), '${service.clientAddress}/128')
          }
          file ${service.zone} mesh {
            reload 1s
          }
        }
      '')
      services)
    + ''
      .:53 {
        bind ::
        errors
        template IN ANY {
          rcode REFUSED
        }
      }
    ''
  );
  nsswitch =
    pkgs.runCommand "idr-mesh-nsswitch.conf" {
      idrNssSource = config.environment.etc."nsswitch.conf".source;
    } ''
      ${lib.getExe pkgs.buildPackages.gawk} '
        /^[[:space:]]*hosts[[:space:]]*:/ { hosts = 1 }
        hosts { hosts = /\\$/; next }
        { print }
        END { print "hosts: files dns" }
      ' "$idrNssSource" > "$out"
    '';
  dnsServices = name: service: let
    namespace = "idr-mesh-netns@${name}.service";
    state = "/run/idr-mesh-dns-link/${name}/state.json";
    inventory = pkgs.writeText "idr-mesh-dns-${service.hash}.json" (builtins.toJSON {
      services.${name} = profiles.${name};
    });
    resolv = pkgs.writeText "idr-mesh-resolv-${service.hash}.conf" ''
      nameserver ${service.serverAddress}
    '';
  in {
    ${name} = {
      environment.LD_LIBRARY_PATH = lib.mkDefault "${userNss}";
      serviceConfig = {
        BindReadOnlyPaths = [
          "${resolv}:/etc/resolv.conf"
          "${nsswitch}:/etc/nsswitch.conf"
        ];
        IPAddressAllow = ["${service.serverAddress}/128"];
      };
    };
    "idr-mesh-dns-link@${name}" = {
      description = "Mesh DNS link for ${name}";
      bindsTo = [namespace "idr-mesh-dns-netns.service"];
      after = [namespace "idr-mesh-dns-netns.service"];
      partOf = [namespace "idr-mesh-dns-netns.service"];
      restartTriggers = [inventory];
      unitConfig.StopWhenUnneeded = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = utils.escapeSystemdExecArgs [
          setupExe
          "dns-transport"
          "create-link"
          "--"
          name
          inventory
          state
        ];
        ExecStopPost = utils.escapeSystemdExecArgs [setupExe "dns-transport" "remove-link" "--" name inventory state];
        RuntimeDirectory = "idr-mesh-dns-link/${name}";
        RuntimeDirectoryMode = "0700";
        CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_SYS_ADMIN" "CAP_DAC_OVERRIDE"];
        NoNewPrivileges = true;
        UMask = "0077";
      };
    };
  };
  uniqueField = field: let
    values = lib.mapAttrsToList (_: service: service.${field}) services;
  in
    builtins.length values == builtins.length (lib.unique values);
in {
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = uniqueField "interface" && uniqueField "clientAddress";
        message = "Mesh DNS links must have distinct interface names and IPv6 subnets.";
      }
    ];

    users.groups.${readerGroup} = {};
    systemd.tmpfiles.rules = [
      "d /run/nscd 0755 - - -"
      "d /run/idr-mesh-dns 0750 root ${readerGroup} -"
      # netd writes each workload's zone below from the peers it installed.
      "d /run/idr-mesh-dns/zones 0750 root ${readerGroup} -"
    ];
    environment.etc = {
      "idr-mesh/dns.json".text = builtins.toJSON {services = profiles;};
      "idr-mesh/dns-server.nft".source = firewall.server;
      "idr-mesh/Corefile".source = corefile;
    };

    systemd.services =
      lib.concatMapAttrs dnsServices services
      // lib.optionalAttrs config.services.nscd.enable {
        nscd.serviceConfig.RuntimeDirectoryPreserve = true;
      }
      // {
        idr-mesh-dns-netns = {
          description = "Mesh DNS network namespace";
          after = ["systemd-tmpfiles-setup.service"];
          reloadTriggers = [firewall.server];
          unitConfig.StopWhenUnneeded = true;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${setupExe} dns-transport create-dns /etc/idr-mesh/dns-server.nft";
            ExecReload = "${setupExe} dns-transport configure-dns /etc/idr-mesh/dns-server.nft";
            ExecStopPost = "${setupExe} dns-transport remove-dns";
            RuntimeDirectory = "idr-mesh-dns-netns";
            RuntimeDirectoryMode = "0700";
            RuntimeDirectoryPreserve = true;
            CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_SYS_ADMIN"];
            NoNewPrivileges = true;
          };
        };
        idr-mesh-dns = {
          description = "Mesh DNS resolver";
          environment.LD_LIBRARY_PATH = lib.mkDefault "${userNss}";
          bindsTo = ["idr-mesh-dns-netns.service"];
          requires = ["systemd-tmpfiles-setup.service"];
          after = ["idr-mesh-dns-netns.service" "systemd-tmpfiles-setup.service"];
          partOf = ["idr-mesh-dns-netns.service"];
          reloadTriggers = [corefile];
          unitConfig = {
            StartLimitIntervalSec = 0;
            StopWhenUnneeded = true;
          };
          serviceConfig = {
            Type = "exec";
            ExecStart = "${lib.getExe pkgs.coredns} -conf=/etc/idr-mesh/Corefile";
            ExecReload = "${lib.getExe' pkgs.coreutils "kill"} -USR1 $MAINPID";
            Restart = "on-failure";
            RestartSec = "5s";
            DynamicUser = true;
            Group = readerGroup;
            NetworkNamespacePath = "/run/idr-mesh-dns-netns/namespace";
            BindReadOnlyPaths = ["/run/idr-mesh-dns"];
            InaccessiblePaths = ["/run/nscd"];
            CapabilityBoundingSet = ["CAP_NET_BIND_SERVICE"];
            AmbientCapabilities = ["CAP_NET_BIND_SERVICE"];
            NoNewPrivileges = true;
            ProtectHome = true;
          };
        };
      };
  };
}

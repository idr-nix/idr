top: {
  config,
  lib,
  utils,
  ...
}: let
  cfg = config.idr.etcd;
  instances = lib.filterAttrs (_: instance: instance.enable) cfg.instances;
  interface = "idr-etcd-wg";
  deviceUnit = "sys-subsystem-net-devices-${utils.escapeSystemdPath interface}.device";
  networkSecrets =
    {idr-etcd-private-key = cfg.privateNetwork.privKey;}
    // lib.listToAttrs (lib.imap0 (index: peer:
      lib.nameValuePair "idr-etcd-peer-${toString index}" peer.psk)
    cfg.privateNetwork.peers);
  networkTargets = lib.unique (map (secret: secret.restartTarget) (lib.attrValues networkSecrets));
  rules =
    (map (peer: {
        source = peer.endpoint.address;
        protocol = "udp";
        port = cfg.privateNetwork.listenPort;
      })
      cfg.privateNetwork.peers)
    ++ lib.concatMap (instance:
      (map (source: {
          inherit source;
          protocol = "tcp";
          port = instance.publicPort;
        })
        instance.allowedIPs)
      ++ map (peer: {
        source = peer.address;
        destination = instance.address;
        inherit interface;
        protocol = "tcp";
        port = 65535;
      }) (lib.attrValues instance.peers))
    (lib.attrValues instances);
in {
  config = lib.mkIf (cfg.enable && instances != {}) {
    networking.useNetworkd = true;
    networking.firewall = {
      extraInputRules = lib.mkIf config.networking.nftables.enable (lib.concatMapStringsSep "\n" (rule: let
        family =
          if lib.hasInfix ":" rule.source
          then "ip6"
          else "ip";
      in
        lib.optionalString (rule ? interface) ''iifname "${rule.interface}" ''
        + "${family} saddr ${rule.source} "
        + lib.optionalString (rule ? destination) "${family} daddr ${rule.destination} "
        + "${rule.protocol} dport ${toString rule.port} accept")
      rules);
      extraCommands = lib.mkIf (!config.networking.nftables.enable) (lib.concatMapStringsSep "\n" (rule:
        lib.escapeShellArgs ([
            (
              if lib.hasInfix ":" rule.source
              then "ip6tables"
              else "iptables"
            )
            "-A"
            "nixos-fw"
            "-s"
            rule.source
            "-p"
            rule.protocol
            "--dport"
            (toString rule.port)
          ]
          ++ lib.optionals (rule ? interface) ["-i" rule.interface]
          ++ lib.optionals (rule ? destination) ["-d" rule.destination]
          ++ ["-j" "nixos-fw-accept"]))
      rules);
    };

    systemd.network = {
      enable = true;
      netdevs.${interface} = {
        netdevConfig = {
          Kind = "wireguard";
          Name = interface;
          MTUBytes = "1420";
        };
        wireguardConfig = {
          PrivateKey = "@idr-etcd-private-key";
          ListenPort = cfg.privateNetwork.listenPort;
        };
        wireguardPeers =
          lib.imap0 (index: peer: {
            PublicKey = peer.pubKey;
            PresharedKey = "@idr-etcd-peer-${toString index}";
            AllowedIPs = map (name: "${top.idr-lib.mkIPv6 "fdc1:ae6a:1782" name}/128") peer.etcdPeers;
            Endpoint = "${top.idr-lib.normalizeHost peer.endpoint.address}:${toString peer.endpoint.port}";
          })
          cfg.privateNetwork.peers;
      };
      networks.${interface} = {
        matchConfig.Name = interface;
        address = map (instance: "${instance.address}/48") (lib.attrValues instances);
        networkConfig.LinkLocalAddressing = "no";
        # Co-located clusters must use a source address from the destination's cluster.
        routes = lib.attrValues (lib.listToAttrs (lib.concatMap (instance:
          map (peer:
            lib.nameValuePair peer.address {
              Destination = "${peer.address}/128";
              PreferredSource = instance.address;
            }) (lib.attrValues instance.peers)) (lib.attrValues instances)));
      };
    };

    fileSystems = lib.mapAttrs' (name: instance:
      lib.nameValuePair "/var/lib/private/idr-etcd-${name}" {
        device = instance.dataDir;
        fsType = "none";
        options = ["bind"];
      })
    instances;

    systemd.services =
      {
        systemd-networkd = {
          wants = networkTargets;
          after = networkTargets;
          partOf = networkTargets;
          serviceConfig.LoadCredential = lib.mapAttrsToList (name: secret: "${name}:${secret.path}") networkSecrets;
        };
      }
      // lib.mapAttrs' (name: instance: let
        unitName = "idr-etcd-${name}";
        credentials = "/run/credentials/${unitName}.service";
        targets = lib.unique [instance.cert.restartTarget instance.certKey.restartTarget];
        peerURL = address: "http://${top.idr-lib.normalizeHost address}:65535";
      in
        lib.nameValuePair unitName {
          description = "etcd member ${name}";
          wantedBy = ["multi-user.target"];
          requires = [deviceUnit];
          wants = targets;
          after = [deviceUnit "network.target"] ++ targets;
          partOf = targets;
          environment = {
            ETCD_NAME = name;
            ETCD_DATA_DIR = "/var/lib/${unitName}";
            ETCD_CERT_FILE = "${credentials}/cert";
            ETCD_KEY_FILE = "${credentials}/cert-key";
            ETCD_INITIAL_CLUSTER_TOKEN = instance.clusterToken;
            ETCD_INITIAL_CLUSTER = lib.concatStringsSep "," (
              ["${name}=${peerURL instance.address}"]
              ++ lib.mapAttrsToList (name: peer: "${name}=${peerURL peer.address}") instance.peers
            );
            ETCD_INITIAL_ADVERTISE_PEER_URLS = peerURL instance.address;
            ETCD_LISTEN_PEER_URLS = peerURL instance.address;
            ETCD_LISTEN_CLIENT_URLS = "https://[::]:${toString instance.publicPort}";
            ETCD_ADVERTISE_CLIENT_URLS = "https://${top.idr-lib.normalizeHost instance.publicHostname}:${toString instance.publicPort}";
          };
          serviceConfig = {
            Type = "notify";
            ExecStart = "${instance.package}/bin/etcd";
            Restart = "on-failure";
            RestartSec = "5s";
            TimeoutStartSec = "300s";
            LimitNOFILE = lib.mkDefault 40000;
            DynamicUser = true;
            StateDirectory = unitName;
            StateDirectoryMode = "0700";
            LoadCredential = ["cert:${instance.cert.path}" "cert-key:${instance.certKey.path}"];
            IOSchedulingClass = "best-effort";
            IOSchedulingPriority = 2;
          };
        })
      instances;
  };
}

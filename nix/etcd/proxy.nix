top: {
  config,
  lib,
  utils,
  ...
}: let
  cfg = config.idr.etcd;
  proxies = lib.filterAttrs (_: proxy: proxy.enable) cfg.proxy;
  address = name: top.idr-lib.mkLocalIPv6 "idr-etcd-proxy-${name}";
  interface = "idr-etcd-proxy";
  # Only privileged processes may bind it, so no local process can take it over
  # while the proxy is down.
  port = "1023";
  deviceUnit = "sys-subsystem-net-devices-${utils.escapeSystemdPath interface}.device";
in {
  config = lib.mkIf (cfg.enable && proxies != {}) {
    systemd.network = {
      enable = true;
      netdevs.${interface}.netdevConfig = {
        Name = interface;
        Kind = "dummy";
      };
      networks.${interface} = {
        matchConfig.Name = interface;
        address = lib.mapAttrsToList (name: _: "${address name}/128") proxies;
      };
    };
    networking.hosts = lib.mapAttrs' (name: _: lib.nameValuePair (address name) ["${name}.etcd.internal"]) proxies;

    systemd.services = lib.mapAttrs' (name: proxy:
      lib.nameValuePair "idr-etcd-proxy-${name}" {
        description = "etcd gRPC proxy ${name}";
        wantedBy = ["multi-user.target"];
        requires = [deviceUnit];
        after = [deviceUnit "network.target"];
        # grpc-proxy's --cacert also checks an absent client certificate. Use Go's trust store.
        environment = lib.optionalAttrs (proxy.caCert != null) {
          SSL_CERT_FILE = proxy.caCert;
        };
        serviceConfig = {
          Type = "notify";
          Restart = "on-failure";
          RestartSec = "5s";
          DynamicUser = true;
          AmbientCapabilities = ["CAP_NET_BIND_SERVICE"];
          CapabilityBoundingSet = ["CAP_NET_BIND_SERVICE"];
          ExecStart = lib.escapeShellArgs ([
              "${proxy.package}/bin/etcd"
              "grpc-proxy"
              "start"
              "--endpoints"
              (lib.concatMapStringsSep "," (endpoint: "https://${top.idr-lib.normalizeHost endpoint.domain}:${toString endpoint.port}") proxy.endpoints)
              "--listen-addr"
              "[${address name}]:${port}"
              "--advertise-client-url"
              "http://${name}.etcd.internal:${port}"
            ]
            ++ proxy.extraArgs);
        };
      })
    proxies;
  };
}

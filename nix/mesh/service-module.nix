top: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.idr.mesh;
  serviceIdPattern = "[0-9a-f]{12}";
  ports = description:
    mkOption {
      type = types.either (types.ints.between 1 65535) (types.submodule {
        options = {
          from = mkOption {
            type = types.ints.between 1 65535;
            description = "First port of the range.";
          };
          to = mkOption {
            type = types.ints.between 1 65535;
            description = "Last port of the range.";
          };
        };
      });
      example = {
        from = 50000;
        to = 60000;
      };
      inherit description;
    };
  proto = description:
    mkOption {
      type = types.enum ["tcp" "udp"];
      inherit description;
    };
in {
  _class = "service";
  key = toString ./service-module.nix;

  options.idr.mesh = {
    id = mkOption {
      type = types.strMatching serviceIdPattern;
      example = "222222222222";
      description = "48-bit service ID as twelve lowercase hexadecimal digits. Replicas share this ID.";
    };

    peers = mkOption {
      type = types.attrsOf (types.submodule {
        options.psk = mkOption {
          type = top.idr-lib.types.secretOrSource;
          description = "WireGuard preshared key shared by this pair of services, as a runtime secret reference or a secret source.";
        };
      });
      default = {};
      description = "Permitted peer services, keyed by their twelve-digit lowercase hexadecimal service IDs. Configure the reciprocal relationship with the same PSK on each peer.";
    };

    publish = mkOption {
      type = types.listOf (types.submodule {
        options = {
          proto = proto "Transport protocol of the published port.";
          port = ports "Port, or range of ports, on the host's addresses, forwarded to the same port of the workload.";
        };
      });
      default = [];
      example = [
        {
          proto = "tcp";
          port = 443;
        }
      ];
      description = "Ports of the host's addresses to forward to this workload. Connections from other machines keep their client address.";
    };

    internet = {
      enable = lib.mkEnableOption "connections from this workload to the internet, through the host and only as `allow` permits";
      allow = mkOption {
        type = types.listOf (types.submodule {
          options = {
            proto = proto "Transport protocol of the allowed connections.";
            port = ports "Port, or range of ports, that the connections may go to.";
            destinations = mkOption {
              type = types.listOf types.nonEmptyStr;
              default = [];
              example = ["203.0.113.0/24" "2001:db8::/32"];
              description = "Addresses or networks that the connections may go to; any when empty.";
            };
          };
        });
        default = [];
        example = [
          {
            proto = "tcp";
            port = 443;
          }
        ];
        description = "Connections that the workload may open to the internet. Their source becomes the host's address.";
      };
    };
  };

  config.assertions = [
    {
      assertion = lib.all (id: builtins.match serviceIdPattern id != null) (lib.attrNames cfg.peers);
      message = "idr.mesh.peers keys must be twelve lowercase hexadecimal digits.";
    }
    {
      assertion = lib.all (entry: lib.isInt entry.port || entry.port.from <= entry.port.to) (cfg.publish ++ cfg.internet.allow);
      message = "idr.mesh.publish and idr.mesh.internet.allow port ranges must not end before they start.";
    }
  ];

  # The publish link's unit exists whether or not ports are published, so
  # publishing never changes this unit.
  config.systemd.service = {name, ...}: {
    wants = ["idr-mesh-agent.service" "idr-mesh-apply@${name}.service" "idr-mesh-dns.service"];
    requires = ["idr-mesh-netns@${name}.service" "idr-mesh-dns-link@${name}.service" "idr-mesh-publish@${name}.service" "systemd-tmpfiles-setup.service"];
    after = ["idr-mesh-netns@${name}.service" "idr-mesh-dns-link@${name}.service" "idr-mesh-publish@${name}.service" "idr-mesh-dns.service" "systemd-tmpfiles-setup.service"];
    serviceConfig = {
      NetworkNamespacePath = "/run/idr-mesh-netns/${name}/namespace";
      InaccessiblePaths = ["/run/nscd"];
      CapabilityBoundingSet = lib.mkAfter ["~CAP_NET_ADMIN CAP_NET_RAW CAP_SYS_ADMIN"];
      NoNewPrivileges = true;
      RestrictNamespaces = true;
    };
  };
}

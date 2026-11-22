top: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.idr.mesh;
  serviceIdPattern = "[0-9a-f]{12}";
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
          proto = mkOption {
            type = types.enum ["tcp" "udp"];
            description = "Transport protocol of the published port.";
          };
          port = mkOption {
            type = types.ints.between 1 65535;
            description = "Port on the host's addresses, forwarded to the same port of the workload.";
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
      description = "Ports of the host's addresses to forward to this workload. Connections from other machines keep their client address.";
    };
  };

  config.assertions = [
    {
      assertion = lib.all (id: builtins.match serviceIdPattern id != null) (lib.attrNames cfg.peers);
      message = "idr.mesh.peers keys must be twelve lowercase hexadecimal digits.";
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

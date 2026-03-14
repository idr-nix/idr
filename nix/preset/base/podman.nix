top: moduleArgs @ {
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
  podmanInterface = config.virtualisation.podman.defaultNetwork.settings.network_interface or "podman0";
in {
  options.idr.preset.base = {
    podman = {
      IPv4 = {
        gateway = lib.mkOption {
          description = ''
            Default IPv4 gateway address for the podman network bridge.
          '';
          type = lib.types.str;
          default = "10.88.0.1";
        };
        subnet = lib.mkOption {
          description = ''
            Default IPv4 subnet for the podman network bridge.
          '';
          type = lib.types.str;
          default = "10.88.0.0/16";
        };
      };
      IPv6 = {
        gateway = lib.mkOption {
          description = ''
            Default IPv6 gateway address for the podman network bridge.
          '';
          type = lib.types.str;
          default = "fda8:35f4:8bb1::1";
        };
        subnet = lib.mkOption {
          description = ''
            Default IPv6 subnet for the podman network bridge.
          '';
          type = lib.types.str;
          default = "fda8:35f4:8bb1::/48";
        };
      };
    };
  };

  config = lib.mkIf cfg.base.enable (lib.mkMerge [
    # podman
    (lib.mkIf (!config.boot.isContainer) {
      virtualisation.containers.containersConf.settings = {
        network.dns_bind_port = lib.mkDefault 64999;
      };

      networking.firewall.extraInputRules = ''
        iifname "${podmanInterface}" udp dport ${toString config.virtualisation.containers.containersConf.settings.network.dns_bind_port} accept
        iifname "${podmanInterface}" tcp dport ${toString config.virtualisation.containers.containersConf.settings.network.dns_bind_port} accept
      '';

      virtualisation.podman.enable = lib.mkDefault true;

      virtualisation.podman.defaultNetwork.settings = {
        dns_enabled = lib.mkDefault true;
        ipv6_enabled = lib.mkDefault true;
        subnets = [
          cfg.base.podman.IPv4
          cfg.base.podman.IPv6
        ];
      };
    })
  ]);
}

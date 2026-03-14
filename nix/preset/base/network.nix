top: moduleArgs @ {
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
in {
  options.idr.preset.base = {
  };

  config = lib.mkIf cfg.base.enable (lib.mkMerge [
    # network
    (lib.mkIf (!config.boot.isContainer) {
      networking = {
        hostId = lib.mkIf (cfg.base.id != null) (lib.mkOverride 999 (builtins.substring 0 8 cfg.base.id));
        useNetworkd = lib.mkDefault true;
        useDHCP = lib.mkDefault true;
        nftables = {
          enable = lib.mkDefault true;
        };
      };

      systemd.network.enable = lib.mkDefault true;
      boot.initrd.network.enable = lib.mkDefault true;
      boot.initrd.systemd.network.units =
        lib.mapAttrs (_: unit: lib.mkDefault unit) config.systemd.network.units;

      # Allow PMTU / DHCP
      networking.firewall.allowPing = true;

      # Keep dmesg/journalctl -k output readable by NOT logging
      # each refused connection on the open internet.
      networking.firewall.logRefusedConnections = lib.mkDefault false;

      # The notion of "online" is a broken concept
      # https://github.com/systemd/systemd/blob/e1b45a756f71deac8c1aa9a008bd0dab47f64777/NEWS#L13
      systemd.services.NetworkManager-wait-online.enable = false;
      systemd.network.wait-online.enable = false;

      # Do not take down the network for too long when upgrading,
      # This also prevents failures of services that are restarted instead of stopped.
      # It will use `systemctl restart` rather than stopping it with `systemctl stop`
      # followed by a delayed `systemctl start`.
      systemd.services.systemd-networkd.stopIfChanged = false;
      # Services that are only restarted might be not able to resolve when resolved is stopped before
      systemd.services.systemd-resolved.stopIfChanged = false;
    })

    (lib.mkIf config.boot.isContainer {
      services.resolved.enable = lib.mkDefault false;
    })
  ]);
}

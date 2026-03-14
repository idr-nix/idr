top: {
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [../qemu-network/options.nix];

  options.idr.qemu-host.enable = lib.mkOption {
    description = ''
      Whether to configure a shared IPv6 bridge for local QEMU machines.
    '';
    type = lib.types.bool;
    default = false;
  };

  config = lib.mkIf config.idr.qemu-host.enable {
    systemd.network = {
      enable = true;
      netdevs."40-idr0".netdevConfig = {
        Kind = "bridge";
        Name = "idr0";
      };
      networks."40-idr0" = {
        matchConfig.Name = "idr0";
        address = ["${config.idr.qemu.networkPrefix}::1/48"];
        linkConfig.RequiredForOnline = false;
        networkConfig = {
          ConfigureWithoutCarrier = true;
          DHCP = "no";
          LinkLocalAddressing = "ipv6";
          IPv6AcceptRA = false;
        };
      };
    };

    environment.etc."qemu/bridge.conf".text = "allow idr0";

    security.wrappers.qemu-bridge-helper = {
      setuid = true;
      owner = "root";
      group = "root";
      source = lib.mkDefault "${pkgs.qemu}/libexec/qemu-bridge-helper";
    };
  };
}

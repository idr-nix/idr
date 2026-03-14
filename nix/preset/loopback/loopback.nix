top: moduleArgs @ {
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.idr.preset;
in {
  options.idr.preset.loopback = {
    addresses = lib.mkOption {
      description = ''
        Additional loopback addresses.
      '';
      type = lib.types.listOf lib.types.str;
      example = ["10.0.0.4/32" "fd00::123/128"];
      default = [];
    };
  };

  config = lib.mkIf (builtins.length cfg.loopback.addresses > 0) {
    systemd.network.enable = true;
    systemd.network.netdevs = {
      "10-idr-lo" = {
        netdevConfig = {
          Name = "idr-lo";
          Kind = "dummy";
        };
      };
    };
    systemd.network.networks."10-idr-lo" = {
      matchConfig = {
        Name = "idr-lo";
      };
      networkConfig.Address = cfg.loopback.addresses;
    };
  };
}

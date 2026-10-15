top: {
  config,
  lib,
  ...
}: {
  options.idr.microvm.network = {
    ipv4Subnet = lib.mkOption {
      type = lib.types.str;
      default = "10.1.0.0/16";
      description = "IPv4 subnet used by MicroVM hosts and idr-mk-machine address allocation.";
    };
    ipv6Prefix = lib.mkOption {
      type = lib.types.strMatching "[fF][dD][0-9a-fA-F]{2}(:[0-9a-fA-F]{4}){2}";
      default = "fd54:0fb7:359f";
      description = "ULA /48 prefix, written as three full hextets without a trailing colon or prefix length.";
    };
  };

  config.flake.idrMicrovm = {
    network = config.idr.microvm.network;
    machines = lib.mapAttrs (_: machine: {
      inherit (machine.config.idr.microvmGuest.network) ipv4Address;
    }) (lib.filterAttrs (_: machine: machine.config.idr.microvmGuest.enable or false) config.flake.nixosConfigurations);
  };
}

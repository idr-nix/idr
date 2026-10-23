top: {...}: {
  config = {
    systemd.network.networks."02:d9:6c:90:70:e8" = {
      matchConfig.MACAddress = "02:d9:6c:90:70:e8";
      address = [
        "192.0.2.10/24"
        "2001:db8::10/64"
      ];
      routes = [
        {
          Gateway = "fe80::1";
          GatewayOnLink = true;
        }
        {
          Gateway = "192.0.2.1";
        }
      ];
      linkConfig.RequiredForOnline = "routable";
    };
  };
}

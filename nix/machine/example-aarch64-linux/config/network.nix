top: {...}: {
  config = {
    systemd.network.networks."02:0b:2e:8d:0a:82" = {
      matchConfig.MACAddress = "02:0b:2e:8d:0a:82";
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

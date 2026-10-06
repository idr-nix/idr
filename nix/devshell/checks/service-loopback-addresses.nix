top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    addresses = lib.genAttrs ["first" "second"] (name: top.idr-lib.mkLocalIPv6 "docs-port-${name}");
  in {
    checks.service-loopback-addresses = pkgs.testers.runNixOSTest {
      name = "service-loopback-addresses";

      nodes.machine = {pkgs, ...}: {
        imports = builtins.attrValues top.self.modules.nixos;
        _module.args.inputs = top.inputs;

        virtualisation = {
          memorySize = 1024;
          cores = 2;
        };
        networking.useDHCP = false;
        environment.systemPackages = [pkgs.curl];

        idr.preset.loopback.addresses =
          [
            "192.0.2.20/32"
            "2001:db8::20/128"
          ]
          ++ map (address: "${address}/128") (builtins.attrValues addresses);

        services.nginx = {
          enable = true;
          virtualHosts =
            lib.mapAttrs (name: address: {
              listen = [
                {
                  addr = "[${address}]";
                  port = 65535;
                }
              ];
              root = pkgs.writeTextDir "index.html" "${name} instance";
            })
            addresses;
        };
        systemd.services.nginx = {
          wants = ["network-online.target"];
          after = ["network-online.target"];
        };
      };

      testScript = ''
        import json

        start_all()
        machine.wait_for_unit("nginx.service")

        with subtest("assign the documented extra addresses to idr-lo"):
            interfaces = json.loads(machine.succeed("ip -j address show dev idr-lo"))
            configured = {
                (address["local"], address["prefixlen"])
                for address in interfaces[0]["addr_info"]
            }
            assert ("192.0.2.20", 32) in configured
            assert ("2001:db8::20", 128) in configured

        with subtest("serve independent instances on the same port at stable local IPv6 addresses"):
            addresses = json.loads('${builtins.toJSON addresses}')
            assert len(set(addresses.values())) == 2
            for name, address in addresses.items():
                machine.wait_until_succeeds(
                    f"curl --noproxy '*' --fail --silent 'http://[{address}]:65535/'"
                )
                assert machine.succeed(
                    f"curl --noproxy '*' --fail --silent 'http://[{address}]:65535/'"
                ) == f"{name} instance"
            listeners = machine.succeed("ss -H -ltn 'sport = :65535'")
            assert len(listeners.splitlines()) == 2
            assert "[::]:65535" not in listeners and "*:65535" not in listeners
      '';
    };
  };
}

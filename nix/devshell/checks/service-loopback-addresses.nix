top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    inherit (pkgs.stdenv.hostPlatform) isLinux;
    addresses = lib.genAttrs ["first" "second"] (name: top.idr-lib.mkLocalIPv6 "docs-port-${name}");
  in {
    checks.service-loopback-addresses = pkgs.testers.runNixOSTest {
      imports = [top.self.modules.nixosTest.disk-storage];
      name = "service-loopback-addresses";
      requiredFeatures.kvm = false;

      defaults = {pkgs, ...}: {
        imports = builtins.attrValues top.self.modules.nixos;
        _module.args.inputs = top.inputs;

        networking.useDHCP = false;
        networking.firewall = {
          enable = true;
          allowedTCPPorts = [8080 65535];
          trustedInterfaces = ["loopback-peer"];
        };
        environment.systemPackages = [pkgs.curl];

        idr.preset.loopback.addresses =
          [
            "192.0.2.20/32"
            "2001:db8::20/128"
            "192.0.2.21/24"
            "2001:db8::21/64"
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
            addresses
            // {
              probe = {
                listen = [
                  {
                    addr = "0.0.0.0";
                    port = 8080;
                  }
                  {
                    addr = "[::]";
                    port = 8080;
                  }
                ];
                root = pkgs.writeTextDir "index.html" "probe";
              };
            };
        };
        systemd.services.nginx = {
          wants = ["network-online.target"];
          after = ["network-online.target"];
        };
      };

      containers = lib.optionalAttrs isLinux {
        machine.networking.useHostResolvConf = false;
      };
      nodes = lib.optionalAttrs (!isLinux) {
        machine.virtualisation = {
          memorySize = 1024;
          cores = 2;
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

        with subtest("protect only configured hosts before trusted-interface and port accepts"):
            machine.succeed(
                "ip netns add peer",
                "ip link add loopback-peer type veth peer name peer0 netns peer",
                "ip addr add 198.51.100.1/24 dev loopback-peer",
                "ip -6 addr add 2001:db8:ffff::1/64 dev loopback-peer nodad",
                "ip link set loopback-peer up",
                "ip -n peer link set lo up",
                "ip -n peer addr add 198.51.100.2/24 dev peer0",
                "ip -n peer -6 addr add 2001:db8:ffff::2/64 dev peer0 nodad",
                "ip -n peer link set peer0 up",
                "ip -n peer route add default via 198.51.100.1",
                "ip -n peer -6 route add default via 2001:db8:ffff::1",
                "ip addr add 192.0.2.22/32 dev lo",
                "ip -6 addr add 2001:db8::22/128 dev lo nodad",
            )

            def request(address, remote=False, port=8080):
                host = f"[{address}]" if ":" in address else address
                prefix = "ip netns exec peer " if remote else ""
                return prefix + f"curl --noproxy '*' --fail --silent --connect-timeout 2 --max-time 3 'http://{host}:{port}/'"

            for address in ["192.0.2.22", "2001:db8::22"]:
                machine.wait_until_succeeds(request(address, remote=True))
                assert machine.succeed(request(address, remote=True)) == "probe"

            for address in ["192.0.2.20", "2001:db8::20", "192.0.2.21", "2001:db8::21"]:
                assert machine.succeed(request(address)) == "probe"
                status, _ = machine.execute(request(address, remote=True))
                assert status == 28, f"expected timeout for {address}, got {status}"

            for address in addresses.values():
                status, _ = machine.execute(request(address, remote=True, port=65535))
                assert status == 28, f"expected timeout for {address}, got {status}"
      '';
    };
  };
}

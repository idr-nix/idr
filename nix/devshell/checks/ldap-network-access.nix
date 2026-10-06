top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.ldap-network-access = pkgs.testers.runNixOSTest ({ldapCredentials, ...}: {
      imports = [(lib.modules.importApply ./ldap-fixture.nix {inherit top;})];
      name = "ldap-network-access";

      nodes =
        (lib.genAttrs ["client" "blocked"] (name: {pkgs, ...}: {
          networking.useDHCP = false;
          networking.interfaces.eth1 = {
            ipv4.addresses = lib.mkForce [
              {
                address =
                  if name == "client"
                  then "192.168.1.2"
                  else "192.168.1.3";
                prefixLength = 24;
              }
            ];
            ipv6.addresses = lib.mkForce [
              {
                address =
                  if name == "client"
                  then "2001:db8:1::2"
                  else "2001:db8:1:2::3";
                prefixLength = 48;
              }
            ];
          };
          environment.systemPackages = [pkgs.openldap pkgs.netcat];
          environment.variables.LDAPTLS_CACERT = "${ldapCredentials}/ca.pem";
          environment.etc."ldap-test/password".source = "${ldapCredentials}/initial-password";
        }))
        // {
          machine = {config, ...}: {
            networking.interfaces.eth1 = {
              ipv4.addresses = lib.mkForce [
                {
                  address = "192.168.1.1";
                  prefixLength = 24;
                }
              ];
              ipv6.addresses = lib.mkForce [
                {
                  address = "2001:db8:1::1";
                  prefixLength = 48;
                }
              ];
            };
            idr.ldap.main = {
              port = 1636;
              allowedIPs = ["192.168.1.2" "2001:db8:1::/64"];
            };
            idr.ldap.restricted = {
              secondLevelDomain = "example";
              topLevelDomain = "com";
              domain = "ldap-restricted.example.com";
              port = 2636;
              cert = config.idr.secrets.ldap-cert;
              certKey = config.idr.secrets.ldap-cert-key;
              rootPassword = config.idr.secrets.ldap-admin-password;
              allowedIPs = ["192.168.1.3" "2001:db8:1:2::/64"];
            };
            containers.ldap-restricted.config.system.stateVersion = "26.05";
            specialisation.nftables.configuration.networking.nftables.enable = true;
          };
        };
      defaults = {lib, ...}: {
        virtualisation.memorySize = lib.mkDefault 1024;
        virtualisation.cores = lib.mkDefault 1;
      };
      testScript = ''
        start_all()
        for instance in ["main", "restricted"]:
            machine.wait_for_unit("container@ldap-" + instance + ".service")
            machine.wait_until_succeeds("nixos-container run ldap-" + instance + " -- systemctl is-active openldap.service")
        for node in [client, blocked]:
            node.wait_for_unit("network.target")

        for backend in ["iptables", "nftables"]:
            with subtest("allow IPv4 addresses and IPv6 CIDRs on a custom port with " + backend):
                if backend == "nftables":
                    machine.succeed(
                        "/run/current-system/specialisation/nftables/bin/switch-to-configuration test",
                        timeout=180,
                    )
                machine.wait_for_unit("firewall.service" if backend == "iptables" else "nftables.service")
                blocked.succeed("ping -c 1 192.168.1.1")
                blocked.succeed("ping -6 -c 1 2001:db8:1::1")
                for port, allowed, denied in [(1636, client, blocked), (2636, blocked, client)]:
                    for host in ["192.168.1.1", "[2001:db8:1::1]"]:
                        command = (
                            "ldapwhoami -x -o nettimeout=3 -H ldaps://" + host + ":" + str(port) + " "
                            "-D cn=admin,dc=example,dc=com -y /etc/ldap-test/password"
                        )
                        try:
                            allowed.wait_until_succeeds(command, timeout=30)
                        except Exception:
                            for node in [allowed, machine]:
                                print(node.succeed("ip -6 address show dev eth1; ip -6 route; ss -lnt"))
                            print(machine.execute("ip6tables -nvL nixos-fw; nft list ruleset")[1])
                            raise
                        denied.fail(command)
                client.fail("nc -z -w 3 192.168.1.1 636")
      '';
    });
  };
}

top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.ldap-directory-updates = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./ldap-fixture.nix {inherit top;})];
      name = "ldap-directory-updates";

      nodes.machine = {
        specialisation.override.configuration.idr.ldap.main.users.alice.mail = lib.mkForce "updated@example.com";
        specialisation.replace.configuration.idr.ldap.main.users = lib.mkForce {
          standalone = {
            firstName = "Standalone";
            lastName = "Account";
            mail = "standalone@example.com";
          };
        };
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("container@ldap-main.service")
        machine.wait_until_succeeds("nixos-container run ldap-main -- systemctl is-active openldap.service")
        search = (
            "ldapsearch -LLL -x -H ldaps://ldap.example.com "
            "-D cn=admin,dc=example,dc=com -y /etc/ldap-test/password "
            "-b ou=users,dc=example,dc=com '(objectClass=inetOrgPerson)' uid mail"
        )
        initial_system = machine.succeed("readlink -f /run/current-system").strip()
        assert "mail: alice@example.com" in machine.succeed(search)

        with subtest("deploy a directory field override"):
            machine.succeed(initial_system + "/specialisation/override/bin/switch-to-configuration test", timeout=180)
            machine.wait_until_succeeds(search + " | grep -F 'mail: updated@example.com'")
            directory = machine.succeed(search)
            assert "mail: alice@example.com" not in directory
            assert "uid: guest" in directory and "uid: robert" in directory

        with subtest("replace the complete directory user set with mkForce"):
            machine.succeed(initial_system + "/specialisation/replace/bin/switch-to-configuration test", timeout=180)
            machine.wait_until_succeeds(search + " | grep -F 'uid: standalone'")
            directory = machine.succeed(search)
            assert directory.count("dn: uid=") == 1
            assert "mail: standalone@example.com" in directory
            assert "uid: alice" not in directory and "uid: guest" not in directory
      '';
    };
  };
}

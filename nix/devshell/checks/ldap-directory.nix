top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.ldap-directory = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./ldap-fixture.nix {inherit top;})];
      name = "ldap-directory";

      testScript = ''
        start_all()
        machine.wait_for_unit("container@ldap-main.service")
        machine.wait_until_succeeds("nixos-container run ldap-main -- systemctl is-active openldap.service")
        admin = (
            "ldapsearch -LLL -o ldif-wrap=no -x -H ldaps://ldap.example.com "
            "-D cn=admin,dc=example,dc=com -y /etc/ldap-test/password "
            "-b dc=example,dc=com "
        )
        alice = (
            "ldapsearch -LLL -o ldif-wrap=no -x -H ldaps://ldap.example.com "
            "-D uid=alice,ou=users,dc=example,dc=com -w directory-password "
            "-b ou=users,dc=example,dc=com "
        )

        with subtest("publish human team members, field overrides, and additional users over TLS"):
            directory = machine.succeed(admin + "'(objectClass=inetOrgPerson)' '*' '+'")
            for expected in [
                "uid: alice", "cn: Alice", "sn: Reader", "mail: alice@example.com",
                "uidNumber: 1100", "gidNumber: 1101", "homeDirectory: /home/alice",
                "uid: robert", "mail: robert@example.com", "uid: guest",
                "sshPublicKey: ssh-ed25519", "agePublicKey: age1",
                "memberOf: cn=developers,ou=groups,dc=example,dc=com",
            ]:
                assert expected in directory, expected
            assert "old-address@example.com" not in directory
            assert "robot" not in directory
            assert directory.count("dn: uid=") == 3
            group = machine.succeed(admin + "'(cn=developers)' uniqueMember")
            assert "uniqueMember: uid=alice,ou=users,dc=example,dc=com" in group
            assert "uniqueMember: uid=robert,ou=users,dc=example,dc=com" in group

        with subtest("users authenticate and can read only their own entries"):
            own_entry = machine.succeed(alice + "'(objectClass=inetOrgPerson)' uid mail")
            assert "uid: alice" in own_entry and "mail: alice@example.com" in own_entry
            assert own_entry.count("dn: uid=") == 1
            assert "uid: robert" not in own_entry and "uid: guest" not in own_entry
            guest = machine.succeed(
                "ldapwhoami -x -H ldaps://ldap.example.com "
                "-D uid=guest,ou=users,dc=example,dc=com -w additional-password"
            )
            assert "dn:uid=guest,ou=users,dc=example,dc=com" in guest
            anonymous = machine.fail("ldapwhoami -x -H ldaps://ldap.example.com 2>&1")
            assert "Inappropriate authentication (48)" in anonymous
            bad_password = machine.fail(
                "ldapwhoami -x -H ldaps://ldap.example.com "
                "-D uid=alice,ou=users,dc=example,dc=com -w wrong-password 2>&1"
            )
            assert "Invalid credentials (49)" in bad_password

        with subtest("directory contents are read-only even for the administrator"):
            for bind in [
                "-D cn=admin,dc=example,dc=com -y /etc/ldap-test/password",
                "-D uid=alice,ou=users,dc=example,dc=com -w directory-password",
            ]:
                denied = machine.fail(
                    "ldapmodify -x -H ldaps://ldap.example.com " + bind
                    + " -f /etc/ldap-test/readonly.ldif 2>&1"
                )
                assert "Server is unwilling to perform (53)" in denied
            assert "mail: alice@example.com" in machine.succeed(alice + "'(uid=alice)' mail")
      '';
    };
  };
}

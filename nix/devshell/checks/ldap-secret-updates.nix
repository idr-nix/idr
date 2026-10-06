top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.ldap-secret-updates = pkgs.testers.runNixOSTest ({ldapCredentials, ...}: {
      imports = [(lib.modules.importApply ./ldap-fixture.nix {inherit top;})];
      name = "ldap-secret-updates";

      nodes.machine = {
        specialisation.password.configuration.idr.secrets-source.ldap-admin-password.sopsFile = lib.mkForce "${ldapCredentials}/updated.enc.json";
        specialisation.updated.configuration.idr.secrets-source = lib.genAttrs ["ldap-cert" "ldap-cert-key" "ldap-admin-password"] (_: {
          sopsFile = lib.mkForce "${ldapCredentials}/updated.enc.json";
        });
      };

      testScript = ''
        import shlex

        start_all()
        machine.wait_for_unit("container@ldap-main.service")
        machine.wait_until_succeeds("nixos-container run ldap-main -- systemctl is-active openldap.service")
        bind = (
            "ldapwhoami -x -H ldaps://ldap.example.com "
            "-D cn=admin,dc=example,dc=com -y "
        )
        certificate = (
            "set -o pipefail; openssl s_client -connect ldap.example.com:636 -servername ldap.example.com "
            "-CAfile $LDAPTLS_CACERT -verify_return_error </dev/null 2>/dev/null "
            "| openssl x509 -noout -fingerprint -sha256"
        )

        initial_system = machine.succeed("readlink -f /run/current-system").strip()

        with subtest("use initial TLS and administrator credentials"):
            machine.succeed(bind + "/etc/ldap-test/password")
            original_certificate = machine.succeed(certificate).strip()
            original_pid = machine.succeed("systemctl show container@ldap-main -p MainPID --value").strip()
            assert original_pid not in ["", "0"]

        with subtest("deploy only an administrator password update and refresh its mounted file"):
            machine.succeed(
                initial_system + "/specialisation/password/bin/switch-to-configuration test",
                timeout=180,
            )
            machine.wait_until_succeeds(bind + "/etc/ldap-test/updated-password")
            machine.fail(bind + "/etc/ldap-test/password")
            assert machine.succeed(certificate).strip() == original_certificate
            new_pid = machine.succeed("systemctl show container@ldap-main -p MainPID --value").strip()
            assert new_pid not in ["", "0", original_pid]

        with subtest("deploy only the TLS key pair update and serve the new certificate"):
            expected_certificate = machine.succeed(
                "openssl x509 -in ${ldapCredentials}/updated-cert.pem -noout -fingerprint -sha256"
            ).strip()
            machine.succeed(
                initial_system + "/specialisation/updated/bin/switch-to-configuration test",
                timeout=180,
            )
            machine.wait_until_succeeds(bind + "/etc/ldap-test/updated-password")
            machine.wait_until_succeeds(certificate + " | grep -F " + shlex.quote(expected_certificate))
            assert expected_certificate != original_certificate
            machine.succeed(bind + "/etc/ldap-test/updated-password")
            tls_pid = machine.succeed("systemctl show container@ldap-main -p MainPID --value").strip()
            assert tls_pid not in ["", "0", new_pid]
      '';
    });
  };
}

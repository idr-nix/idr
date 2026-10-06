top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    checks.certificates-issue = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./fixtures/certificates-project.nix {
          inherit top;
          project = config.checks.mk-project;
          useVM = !pkgs.stdenv.hostPlatform.isLinux;
        })
      ];
      name = "certificates-issue";
      testScript = ''
        ${builtins.readFile ./fixtures/certificates-setup.py}

        with subtest("configure certificate issuance in a role with operator recipients"):
            prepare_certificates("${./fixtures/certificates-role.nix}")

        with subtest("issue a selected certificate and preserve unrelated encrypted values"):
            operator("nix develop -c idr-update-certs tls-first")
            operator("git diff --exit-code -- nix/role/tls/certs.enc.yaml")
            first = decrypt("nix/role/tls/certs.enc.yaml")
            assert first["application_token"] == "synthetic application value"
            assert "BEGIN CERTIFICATE" in first["tls-first_cert"]
            assert "tls-second_cert" not in first and "tls-fourth_cert" not in first
            assert "tls-third_cert" not in decrypt("nix/role/tls/certs.enc.json")
            assert operator("git show :nix/role/tls/certs.enc.yaml").strip() == operator("cat nix/role/tls/certs.enc.yaml").strip()
            operator("find .data/lego/accounts -type f -exec sha256sum {} + | sort > /tmp/account-before.sha256")

        with subtest("issue all remaining certificates into shared YAML and separate JSON files"):
            operator("nix develop -c idr-update-certs")
            both = decrypt("nix/role/tls/certs.enc.yaml")
            assert both["application_token"] == first["application_token"]
            assert both["tls-first_cert"] == first["tls-first_cert"]
            assert "BEGIN CERTIFICATE" in both["tls-second_cert"]
            assert "BEGIN CERTIFICATE" in both["tls-fourth_cert"]
            assert "BEGIN CERTIFICATE" in decrypt("nix/role/tls/certs.enc.json")["tls-third_cert"]
            operator("sha256sum --check /tmp/account-before.sha256")
            assert operator("find .data/lego/accounts -name account.json | wc -l").strip() == "1"
            operator("git diff --exit-code -- nix/role/tls/certs.enc.yaml nix/role/tls/certs.enc.json")
            operator("git ls-files --error-unmatch nix/role/tls/certs.enc.yaml nix/role/tls/certs.enc.json")

        with subtest("export synthetic issued certificates for the runtime TLS check"):
            machine.succeed("cp /home/operator/project/nix/role/tls/certs.enc.yaml /tmp/certs.enc.yaml")
            machine.succeed("cp /home/operator/.config/idr/operator.age /tmp/operator.age")
            operator('curl --fail --cacert "$IDR_TEST_ACME_CA" https://acme.test:15000/roots/0 > /tmp/certificate-ca.pem')
            # All identities and certificate keys in this output are disposable test data.
            machine.copy_from_machine("/tmp/certs.enc.yaml")
            machine.copy_from_machine("/tmp/operator.age")
            machine.copy_from_machine("/tmp/certificate-ca.pem")
      '';
    };
  };
}

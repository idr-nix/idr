top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    checks.certificates-renew = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./fixtures/certificates-project.nix {
          inherit top;
          project = config.checks.mk-project;
          useVM = !pkgs.stdenv.hostPlatform.isLinux;
        })
      ];
      name = "certificates-renew";
      testScript = ''
        ${builtins.readFile ./fixtures/certificates-setup.py}

        with subtest("issue a certificate with a custom persistent Lego directory"):
            prepare_certificates("${./fixtures/certificates-role.nix}")
            update = 'LEGO_PATH="$PWD/.data/custom-acme" nix develop -c idr-update-certs tls-first'
            operator(update)
            original = decrypt("nix/role/tls/certs.enc.yaml")
            operator("test ! -e .data/lego")
            operator("find .data/custom-acme/accounts -type f -exec sha256sum {} + | sort > /tmp/account-before.sha256")

        def set_issue_age(days):
            # Backdate only synthetic certificate metadata, leaving the system clock alone.
            timestamp = operator("date -u -d '" + str(days) + " days ago' --iso-8601=seconds").strip()
            operator(
                "nix develop -c sops set nix/role/tls/certs.enc.yaml "
                + shlex.quote('["tls-first_issue_date_unencrypted"]') + " "
                + shlex.quote(json.dumps(timestamp))
            )

        with subtest("leave certificates younger than thirty days untouched"):
            set_issue_age(29)
            operator("sha256sum nix/role/tls/certs.enc.yaml > /tmp/recent-cert.sha256")
            operator(update)
            operator("sha256sum --check /tmp/recent-cert.sha256")

        with subtest("replace thirty-day-old certificates and reuse their ACME account"):
            set_issue_age(30)
            operator(update)
            renewed = decrypt("nix/role/tls/certs.enc.yaml")
            assert renewed["tls-first_cert"] != original["tls-first_cert"]
            assert renewed["application_token"] == original["application_token"]
            operator("sha256sum --check /tmp/account-before.sha256")
            assert operator("find .data/custom-acme/accounts -name account.json | wc -l").strip() == "1"
            operator("git diff --exit-code -- nix/role/tls/certs.enc.yaml")

        with subtest("a repeated scheduled update does not rewrite the renewed secrets"):
            operator(
                'LEGO_PATH="$PWD/.data/custom-acme" nix develop -c bash -euo pipefail '
                "<<'COMMANDS'\n"
                "sha256sum nix/role/tls/certs.enc.yaml > /tmp/renewed-cert.sha256\n"
                "idr-update-certs tls-first\n"
                "sha256sum --check /tmp/renewed-cert.sha256\n"
                "COMMANDS"
            )
      '';
    };
  };
}

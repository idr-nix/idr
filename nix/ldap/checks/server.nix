{
  pkgs,
  inputs,
  self,
  ...
}: let
  inherit (pkgs) lib;
  fixtureLib = import ../../lib/lib.nix {
    inherit lib;
    team = ./fixtures;
  };
  ldapModule = lib.modules.importApply ../nixos-module.nix {
    inputs = inputs // {idr = self;};
    idr-lib = fixtureLib;
  };
  secretTarget = "ldap-test-secrets-restart.target";
  secret = name: {
    path = "/run/ldap-test-secrets/${name}";
    group = "root";
    reloadTarget = "ldap-test-secrets-reload.target";
    restartTarget = secretTarget;
  };
  custom = {
    uid = "service";
    firstName = "Custom: Åda\nSecond line";
    lastName = "Account";
    mail = "custom@example.test";
    # This public fixture uses the already-prefixed LDAP password format.
    hashedPassword = "{CRYPT}$6$idrldapcustom$kyDI2fk3CSnUGjZ6dk7uBc3L6f253JMhygV3CmDti2RPwvN4TZXhhtCT5UIWQMyLuLiIWopf8N4U7NctlZnab.";
    groups = ["operators"];
  };
  tlsFixtures =
    pkgs.runCommand "idr-ldap-test-credentials" {
      nativeBuildInputs = [pkgs.openssl];
    } ''
      mkdir -p "$out"
      openssl req -new -newkey ed25519 -noenc \
        -subj /CN=ldap.example.test \
        -keyout "$out/cert-key" -out server.csr
      cat > extensions <<'EOF'
      basicConstraints=critical,CA:TRUE
      keyUsage=critical,digitalSignature,keyCertSign
      extendedKeyUsage=serverAuth
      subjectAltName=DNS:ldap.example.test,IP:192.0.2.1,IP:2001:db8:636::1
      EOF
      for serial in 1 2; do
        openssl x509 -req -in server.csr -signkey "$out/cert-key" \
          -set_serial "$serial" -not_before 20200101000000Z \
          -not_after 21200101000000Z -extfile extensions \
          -out "$out/cert-$serial"
      done
      printf '{CRYPT}%s' "$(openssl passwd -6 -salt idrldaproot admin-test-password)" \
        > "$out/root-password"
      printf '{CRYPT}%s' "$(openssl passwd -6 -salt idrldaproot2 admin-rotated-password)" \
        > "$out/root-password-rotated"
    '';
in
  pkgs.testers.runNixOSTest {
    name = "idr-ldap-server";
    globalTimeout = 5 * 60;

    nodes.machine = {
      imports = [ldapModule];

      virtualisation = {
        memorySize = 1536;
        cores = 2;
      };
      system.switch.enable = true;
      networking.nftables.enable = true;
      networking.dhcpcd.denyInterfaces = ["ldap-server"];
      nix.settings.sandbox = true;
      environment.systemPackages = [pkgs.openldap pkgs.openssl pkgs.iproute2];

      # Only fixture material enters the store. The module receives runtime paths
      # owned by root, so the service must use its real credential integration.
      systemd.targets = {
        ldap-test-secrets-restart = {};
        ldap-test-secrets-reload = {};
      };
      systemd.services.ldap-test-secrets = {
        wantedBy = [secretTarget];
        before = [secretTarget];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "ldap-test-secrets";
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = true;
        };
        path = [pkgs.coreutils];
        script = ''
          install -m 0400 ${tlsFixtures}/cert-1 /run/ldap-test-secrets/cert
          install -m 0400 ${tlsFixtures}/cert-key /run/ldap-test-secrets/cert-key
          install -m 0400 ${tlsFixtures}/root-password /run/ldap-test-secrets/root-password
          install -m 0444 ${tlsFixtures}/cert-1 /run/ldap-test-ca
        '';
      };

      idr.ldap = {
        primary = {
          cert = secret "cert";
          certKey = secret "cert-key";
          rootPassword = secret "root-password";
          secondLevelDomain = "example";
          topLevelDomain = "test";
          allowedIPs = ["192.0.2.2/32" "2001:db8:636::2/128"];
          users = {
            alice.mail = "alice.override@example.test";
            inherit custom;
          };
        };
        disabled.enable = false;
      };

      specialisation.updated.configuration.idr.ldap.primary.users.alice.mail =
        lib.mkForce "alice.updated@example.test";
    };

    testScript = ''
      import json
      fixture_team = json.loads(${builtins.toJSON (builtins.toJSON fixtureLib.team)})
      custom_user = json.loads(${builtins.toJSON (builtins.toJSON custom)})
      tls_fixtures = "${tlsFixtures}"
      ${builtins.readFile ./server/test.py}
    '';
  }

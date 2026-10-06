{top}: {
  lib,
  config,
  ...
}: let
  pkgs = config.nodes.machine.nixpkgs.pkgs;
  # Both the passwords and age identity are deliberately public test data.
  credentials =
    pkgs.runCommand "ldap-test-credentials" {
      nativeBuildInputs = [pkgs.age pkgs.jq pkgs.openssl pkgs.openldap pkgs.sops];
    } ''
      mkdir -p "$out"
      recipient=$(age-keygen -y ${./fixtures/runtime-secrets/key.txt})
      for generation in initial updated; do
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
          -subj /CN=ldap.example.com \
          -addext 'subjectAltName=DNS:ldap.example.com,IP:127.0.0.1,IP:192.168.1.1,IP:2001:db8:1::1' \
          -keyout "$generation-key.pem" -out "$out/$generation-cert.pem" 2>/dev/null
        printf '%s-admin-password' "$generation" > "$out/$generation-password"
        slappasswd -T "$out/$generation-password" > "$generation-password-hash"
        jq -n --rawfile cert "$out/$generation-cert.pem" \
          --rawfile key "$generation-key.pem" \
          --rawfile password "$generation-password-hash" \
          '{"ldap-cert": $cert, "ldap-cert-key": $key, "ldap-admin-password": $password}' \
          > "$generation.json"
        sops --encrypt --age "$recipient" --input-type json --output-type json \
          "$generation.json" > "$out/$generation.enc.json"
      done
      cat "$out/initial-cert.pem" "$out/updated-cert.pem" > "$out/ca.pem"
    '';
  team = builtins.fromTOML (builtins.readFile ./fixtures/ldap/team.toml);
  ldapTop = top // {idr-lib = top.idr-lib // {inherit team;};};
in {
  _module.args.ldapCredentials = credentials;
  globalTimeout = 10 * 60;

  nodes.machine = {
    config,
    pkgs,
    ...
  }: {
    imports =
      [(lib.modules.importApply ../../ldap/nixos-module.nix ldapTop)]
      ++ (with top.self.modules.nixos; [sops secrets systemd]);
    _module.args.inputs = top.inputs;
    virtualisation = {
      memorySize = 2048;
      cores = 2;
    };
    networking.useDHCP = false;
    containers.ldap-main.config.system.stateVersion = "26.05";
    environment.systemPackages = [pkgs.openldap pkgs.openssl];
    environment.variables.LDAPTLS_CACERT = "${credentials}/ca.pem";
    environment.etc."ldap-test/password".source = "${credentials}/initial-password";
    environment.etc."ldap-test/updated-password".source = "${credentials}/updated-password";
    environment.etc."ldap-test/readonly.ldif".text = ''
      dn: uid=alice,ou=users,dc=example,dc=com
      changetype: modify
      replace: mail
      mail: forbidden@example.com
    '';

    sops.age = {
      keyFile = "/var/lib/sops-nix/key.txt";
      sshKeyPaths = [];
    };
    sops.gnupg.sshKeyPaths = [];
    sops.useSystemdActivation = true;
    systemd.tmpfiles.rules = [
      "d /var/lib/sops-nix 0700 root root -"
      "C /var/lib/sops-nix/key.txt 0400 root root - ${./fixtures/runtime-secrets/key.txt}"
    ];
    systemd.services.sops-install-secrets.after = ["systemd-tmpfiles-setup.service"];
    idr.secrets-source = lib.genAttrs ["ldap-cert" "ldap-cert-key" "ldap-admin-password"] (_: {
      sopsFile = "${credentials}/initial.enc.json";
    });
    sops.secrets = lib.genAttrs ["ldap-cert" "ldap-cert-key" "ldap-admin-password"] (_: {format = "json";});
    idr.ldap.main = {
      secondLevelDomain = "example";
      topLevelDomain = "com";
      cert = config.idr.secrets.ldap-cert;
      certKey = config.idr.secrets.ldap-cert-key;
      rootPassword = config.idr.secrets.ldap-admin-password;
      users.alice.mail = "alice@example.com";
      users.additional = {
        uid = "guest";
        firstName = "Extra";
        lastName = "Reader";
        mail = "guest@example.com";
        # Public test password: additional-password. Preserve LDAP scheme prefixes.
        hashedPassword = "{SSHA}fUU6sw1k7qqMQbcy9NH++FQCbTIhYkWZ";
      };
    };
  };
}

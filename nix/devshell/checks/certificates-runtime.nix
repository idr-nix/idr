top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    issued = config.checks.certificates-issue;
  in {
    checks.certificates-runtime = pkgs.testers.runNixOSTest {
      name = "certificates-runtime";
      globalTimeout = 10 * 60;
      defaults = {
        config,
        pkgs,
        ...
      }: let
        cert = config.idr.certs.tls-first;
        references = [cert.cert cert.certKey cert.certPem];
      in {
        imports = with top.self.modules.nixos; [sops secrets certs];
        _module.args.inputs = top.inputs;
        # These artifacts contain only disposable keys and certificates issued by the local test CA.
        sops.age = {
          keyFile = "/var/lib/sops-nix/key.txt";
          sshKeyPaths = [];
        };
        sops.gnupg.sshKeyPaths = [];
        sops.useSystemdActivation = true;
        # The preceding issuance check produces this encrypted file at build time.
        # Validate its contents through real SOPS decryption and TLS handshakes below.
        sops.validateSopsFiles = false;
        systemd.tmpfiles.rules = [
          "d /var/lib/sops-nix 0700 root root -"
          "C /var/lib/sops-nix/key.txt 0400 root root - ${issued}/operator.age"
        ];
        systemd.services.sops-install-secrets.after = ["systemd-tmpfiles-setup.service"];
        idr.certs-source.tls-first = "${issued}/certs.enc.yaml";
        environment.systemPackages = [pkgs.curl pkgs.openssl];
        networking.hosts."127.0.0.1" = ["first.example.test"];
        users.users.tls-app = {
          isSystemUser = true;
          group = "tls-app";
        };
        users.groups.tls-app = {};
        users.users.untrusted.isNormalUser = true;
        systemd.services.tls-chain = {
          wantedBy = ["multi-user.target"];
          wants = map (secret: secret.restartTarget) [cert.cert cert.certKey];
          after = map (secret: secret.restartTarget) [cert.cert cert.certKey];
          partOf = map (secret: secret.restartTarget) [cert.cert cert.certKey];
          serviceConfig = {
            User = "tls-app";
            Group = "tls-app";
            SupplementaryGroups = map (secret: secret.group) [cert.cert cert.certKey];
            ExecStart = "${pkgs.openssl}/bin/openssl s_server -accept 8443 -cert ${cert.cert.path} -cert_chain ${cert.cert.path} -key ${cert.certKey.path} -www -quiet";
          };
        };
        systemd.services.tls-pem = {
          wantedBy = ["multi-user.target"];
          wants = [cert.certPem.restartTarget];
          after = [cert.certPem.restartTarget];
          partOf = [cert.certPem.restartTarget];
          serviceConfig = {
            User = "tls-app";
            Group = "tls-app";
            SupplementaryGroups = [cert.certPem.group];
            ExecStart = "${pkgs.openssl}/bin/openssl s_server -accept 9443 -cert ${cert.certPem.path} -cert_chain ${cert.certPem.path} -key ${cert.certPem.path} -www -quiet";
          };
        };
        environment.etc."certificate-paths".text = lib.concatMapStringsSep "\n" (secret: toString secret.path) references;
      };
      containers = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {machine = {};};
      nodes = lib.optionalAttrs (!pkgs.stdenv.hostPlatform.isLinux) {
        machine = {
          virtualisation = {
            memorySize = 2048;
            cores = 2;
          };
          networking.useDHCP = false;
        };
      };
      testScript = ''
        import shlex

        start_all()
        machine.wait_for_unit("tls-chain.service")
        machine.wait_for_unit("tls-pem.service")
        machine.wait_for_open_port(8443)
        machine.wait_for_open_port(9443)
        certificate, key, pem = machine.succeed("cat /etc/certificate-paths").splitlines()

        with subtest("serve the issued certificate using separate and combined secret references"):
            for port in [8443, 9443]:
                response = machine.succeed(
                    "curl --fail --cacert ${issued}/certificate-ca.pem https://first.example.test:" + str(port)
                )
                assert "s_server" in response
            machine.succeed("openssl x509 -in " + shlex.quote(certificate) + " -noout -checkhost first.example.test")
            machine.succeed("openssl x509 -in " + shlex.quote(certificate) + " -pubkey -noout > /tmp/cert-public.pem")
            machine.succeed("openssl pkey -in " + shlex.quote(key) + " -pubout > /tmp/key-public.pem")
            machine.succeed("cmp /tmp/cert-public.pem /tmp/key-public.pem")

        with subtest("the TLS service can read its key while an unrelated account cannot"):
            machine.succeed("su -s /bin/sh untrusted -c 'id -un'")
            for path in [certificate, key, pem]:
                assert machine.succeed("stat -Lc '%U %a' " + shlex.quote(path)).strip() == "root 440"
                machine.fail("su -s /bin/sh untrusted -c " + shlex.quote("cat " + shlex.quote(path) + " >/dev/null"))
      '';
    };
  };
}

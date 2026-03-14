{
  pkgs,
  inputs,
  self,
}: let
  inherit (pkgs) lib;
  project = "/var/lib/certificate-project";
  fixtures = pkgs.runCommand "idr-certificate-test-identity" {nativeBuildInputs = [pkgs.age];} ''
    mkdir -p "$out"
    age-keygen -o "$out/identity"
    recipient=$(age-keygen -y "$out/identity")
    cat > "$out/sops.yaml" <<EOF
    creation_rules:
      - path_regex: '.*\.enc\.(json|yaml)$'
        age: $recipient
    EOF
  '';
  certificate = domains: sopsFile: {
    inherit domains sopsFile;
    email = "certificates@example.test";
    legoFlags = ["--http" "--http.webroot" "${project}/.data/challenges"];
    envRename.LEGO_CA_CERTIFICATES = "TEST_ACME_CA";
  };
  updater = import ../package.nix {
    inherit pkgs;
    certs = {
      a = certificate ["first.test" "alias.test"] "nix/role/test/certs.enc.yaml";
      b = certificate ["second.test"] "nix/role/test/certs.enc.yaml";
      c = certificate ["third.test"] "nix/role/test/another.enc.json";
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "idr-certificates";
    globalTimeout = 10 * 60;

    nodes.acme = {nodes, ...}: {
      imports = ["${pkgs.path}/nixos/tests/common/acme/server"];
      networking.hosts.${nodes.client.networking.primaryIPAddress} = ["first.test" "alias.test" "second.test" "third.test"];
    };

    nodes.client = {
      config,
      nodes,
      ...
    }: let
      cert = config.idr.certs.a;
    in {
      imports = [
        inputs.sops-nix.nixosModules.sops
        self.modules.nixos.secrets
        self.modules.nixos.certs
      ];
      virtualisation.memorySize = 1536;
      virtualisation.cores = 2;
      system.switch.enable = true;
      networking.firewall.allowedTCPPorts = [80 8443];
      networking.hosts."127.0.0.1" = ["first.test" "alias.test" "second.test" "third.test"];
      environment.systemPackages = [updater pkgs.sops pkgs.gitMinimal pkgs.openssl pkgs.curl pkgs.nushell];
      environment.variables = {
        PRJ_ROOT = project;
        PRJ_DATA_DIR = "${project}/.data";
        SOPS_AGE_KEY_FILE = "/etc/certificate-test-identity";
        LEGO_SERVER = "https://acme.test/dir";
        TEST_ACME_CA = "/etc/certificate-test-ca";
      };
      environment.etc = {
        certificate-test-identity = {
          source = fixtures + "/identity";
          mode = "0400";
        };
        certificate-test-policy.source = fixtures + "/sops.yaml";
        certificate-test-ca.source = nodes.acme.test-support.acme.caCert;
      };
      systemd.tmpfiles.rules = ["d ${project}/.data/challenges 0700 root root -"];
      systemd.services.challenge-http = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 80 --directory ${project}/.data/challenges";
      };

      # The updater produces these encrypted files inside the test VM. SOPS
      # validates and decrypts them at runtime, after real ACME issuance.
      sops = {
        useSystemdActivation = true;
        validateSopsFiles = false;
        age.keyFile = "/etc/certificate-test-identity";
        age.sshKeyPaths = [];
        gnupg.sshKeyPaths = [];
      };
      idr.certs-source = {
        a = "${project}/nix/role/test/certs.enc.yaml";
        b = "${project}/nix/role/test/certs.enc.yaml";
        c = "${project}/nix/role/test/another.enc.json";
      };
      specialisation.updated.configuration.idr.certs-source.a = lib.mkForce "${project}/nix/role/test/next.enc.yaml";
      systemd.services.sops-install-secrets.wantedBy = lib.mkForce [];
      systemd.services.idr-secrets.wantedBy = lib.mkForce ["sysinit-reactivation.target"];
      systemd.services.certificate-consumer = {
        wants = [cert.cert.restartTarget cert.certKey.restartTarget];
        after = ["sops-install-secrets.service"];
        partOf = [cert.cert.restartTarget cert.certKey.restartTarget];
        serviceConfig = {
          DynamicUser = true;
          SupplementaryGroups = [cert.cert.group cert.certKey.group];
          ExecStart = "${pkgs.openssl}/bin/openssl s_server -accept 8443 -cert ${cert.cert.path} -cert_chain ${cert.cert.path} -key ${cert.certKey.path} -www -quiet";
        };
      };
    };

    testScript = builtins.readFile ./certificates/test.py;
  }

# Copied into the generated role by the test, as the documented perSystem example.
top: {lib, ...}: let
  certificate = domain: file: {
    sopsFile = file;
    domains = [domain];
    email = "operator@example.test";
    legoFlags = ["--http" "--http.webroot" "/var/lib/acme-http"];
    envRename.LEGO_CA_CERTIFICATES = "IDR_TEST_ACME_CA";
  };
in {
  flake.modules.nixos.role-tls = lib.modules.importApply ./nixos-module.nix top;
  perSystem = {...}: {
    idr.certs = {
      tls-first = certificate "first.example.test" ./certs.enc.yaml;
      tls-second = certificate "second.example.test" ./certs.enc.yaml;
      tls-third = certificate "third.example.test" ./certs.enc.json;
      tls-fourth = certificate "fourth.example.test" ./certs.enc.yaml;
    };
  };
}

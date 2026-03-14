{pkgs}: let
  inherit (pkgs) lib;
  members = {
    alpha = {
      ipv4 = "192.0.2.11";
      ipv6 = "2001:db8:2379::11";
      publicPort = 2379;
      wireguardPort = 51811;
      publicKey = "wvxSoA7phR9B4WEFhYiGF581q0p+HjvsCHj7ohY56lc=";
    };
    beta = {
      ipv4 = "192.0.2.12";
      ipv6 = "2001:db8:2379::12";
      publicPort = 2381;
      wireguardPort = 51812;
      publicKey = "HkSVFiuMZ2w2feVkXQVwMBEX1KfoWfh3Bmf3d7P0EwA=";
    };
    gamma = {
      ipv4 = "192.0.2.13";
      ipv6 = "2001:db8:2379::13";
      publicPort = 2383;
      wireguardPort = 51813;
      publicKey = "iFUEhCDXGP/c1wLB/tpRuBYgKlkBSIqK5RnHxu+SMm8=";
    };
  };
in {
  inherit members;
  credentials =
    pkgs.runCommand "idr-etcd-test-credentials" {
      nativeBuildInputs = [pkgs.openssl pkgs.wireguard-tools];
    } ''
      mkdir -p "$out"
      openssl req -new -newkey ed25519 -noenc -subj /CN=idr-etcd-test-ca \
        -keyout ca-key -out ca.csr
      cat > ca-extensions <<'EOF'
      basicConstraints=critical,CA:TRUE
      keyUsage=critical,digitalSignature,keyCertSign
      EOF
      openssl x509 -req -in ca.csr -signkey ca-key -set_serial 1 \
        -not_before 20200101000000Z -not_after 21200101000000Z \
        -extfile ca-extensions -out "$out/ca"
      openssl req -new -newkey ed25519 -noenc -subj /CN=untrusted-ca \
        -keyout wrong-ca-key -out wrong-ca.csr
      openssl x509 -req -in wrong-ca.csr -signkey wrong-ca-key -set_serial 1 \
        -not_before 20200101000000Z -not_after 21200101000000Z \
        -extfile ca-extensions -out "$out/wrong-ca"

      ${lib.concatMapStringsSep "\n" (name: let
        member = members.${name};
      in ''
        openssl req -new -newkey ed25519 -noenc -subj /CN=${name}.example.test \
          -keyout "$out/${name}-key" -out ${name}.csr
        cat > ${name}-extensions <<'EOF'
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature
        extendedKeyUsage=serverAuth
        subjectAltName=DNS:${name}.example.test,IP:${member.ipv4},IP:${member.ipv6}
        EOF
        for serial in 1 2; do
          openssl x509 -req -in ${name}.csr -CA "$out/ca" -CAkey ca-key \
            -set_serial "$serial" -not_before 20200101000000Z \
            -not_after 21200101000000Z -extfile ${name}-extensions \
            -out "$out/${name}-cert-$serial"
        done

        # Deterministic public fixture seeds avoid import-from-derivation. Check
        # their published keys with the real WireGuard tool during the build.
        printf '%s' idr-etcd-test-${name} | openssl dgst -sha256 -binary \
          | base64 > "$out/${name}-wireguard-key"
        test "$(wg pubkey < "$out/${name}-wireguard-key")" = '${member.publicKey}'
      '') (builtins.attrNames members)}
      wg genpsk > "$out/wireguard-psk"
      printf '%s' root-test-password > "$out/root-password"
      printf '%s' writer-test-password > "$out/writer-password"
      printf '%s' writer-updated-password > "$out/writer-password-updated"
      printf '%s' writer-rotated-password > "$out/writer-password-rotated"
      printf '%s' reader-test-password > "$out/reader-password"
      printf '%s' obsolete-test-password > "$out/obsolete-password"
      printf '%s' newcomer-test-password > "$out/newcomer-password"
    '';
}

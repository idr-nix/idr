import json
import shlex


project = "/var/lib/certificate-project"
yaml_file = "nix/role/test/certs.enc.yaml"
json_file = "nix/role/test/another.enc.json"


def run(command):
    return client.succeed(f"cd {project} && {command}")


def decrypt(path):
    return json.loads(run(f"sops decrypt --output-type json {path}"))


def digest(path):
    return run(f"sha256sum {path}").split()[0]


def expire(name):
    field = json.dumps([f"{name}_issue_date_unencrypted"])
    value = json.dumps("2000-01-01T00:00:00Z")
    run(f"sops set {yaml_file} {shlex.quote(field)} {shlex.quote(value)}")


start_all()
acme.wait_for_unit("pebble.service")
client.wait_for_unit("challenge-http.service")

with subtest("Issue multiple certificates into shared YAML and separate JSON files"):
    run("git init && git config user.email test@example.test && git config user.name Test")
    run("mkdir -p nix/role/test && cp /etc/certificate-test-policy .sops.yaml")
    run(f"printf '%s' '{{\"unrelated\":\"preserved\"}}' | sops encrypt --input-type json --filename-override {yaml_file} > {yaml_file}")
    client.fail(f"cd {project} && idr-update-certs unknown")
    run("idr-update-certs a")
    run("idr-update-certs")
    before = decrypt(yaml_file)
    assert before["unrelated"] == "preserved"
    assert before["a_cert"] != before["b_cert"]
    assert "BEGIN CERTIFICATE" in before["a_cert"]
    assert "PRIVATE KEY" in before["a_cert_key"]
    assert before["a_cert_key"].strip() in before["a_cert_pem"]
    assert "BEGIN CERTIFICATE" in decrypt(json_file)["c_cert"]
    raw = run(f"cat {yaml_file} {json_file}")
    assert "PRIVATE KEY" not in raw
    assert "BEGIN CERTIFICATE" not in raw
    assert "ENC[AES256_GCM," in raw
    assert run("git diff --cached --name-only").splitlines() == sorted([yaml_file, json_file])
    assert run("stat -c %a .data/lego").strip() == "700"
    accounts = run("find .data/lego/accounts -name account.json").splitlines()
    assert len(accounts) == 1, accounts

with subtest("Expose certificate references to an unprivileged TLS service"):
    client.succeed("systemctl start sops-install-secrets.service idr-secrets.service certificate-consumer.service")
    client.wait_until_succeeds("test -f /run/idr-sops-notify/a_cert")
    client.wait_for_open_port(8443)
    run('curl --fail --cacert "$TEST_ACME_CA" https://acme.test:15000/roots/0 > .data/issuer.pem')
    run("curl --fail --cacert .data/issuer.pem https://first.test:8443/")
    client.succeed("openssl pkey -in /run/secrets/a_cert_pem -noout -check")
    client.succeed("openssl x509 -in /run/secrets/a_cert -noout -checkhost alias.test")
    assert client.succeed("cat /run/secrets/c_cert") == decrypt(json_file)["c_cert"]

with subtest("Fresh certificates need no issuer connection and leave ciphertext unchanged"):
    original = (digest(yaml_file), digest(json_file))
    run("env LEGO_SERVER=https://127.0.0.1:1/dir idr-update-certs")
    assert (digest(yaml_file), digest(json_file)) == original

with subtest("Failed issuance preserves the existing encrypted file"):
    expire("a")
    expire("b")
    original = (digest(yaml_file), digest(json_file))
    client.fail(f"cd {project} && env LEGO_SERVER=https://127.0.0.1:1/dir idr-update-certs a")
    assert (digest(yaml_file), digest(json_file)) == original

with subtest("Selection renews only the requested certificate and refreshes the consumer"):
    invocation = client.succeed("systemctl show -p InvocationID --value certificate-consumer.service").strip()
    run("idr-update-certs a")
    selected = decrypt(yaml_file)
    assert selected["a_cert"] != before["a_cert"]
    assert selected["b_cert"] == before["b_cert"]
    assert selected["b_issue_date_unencrypted"] == "2000-01-01T00:00:00Z"
    assert selected["unrelated"] == "preserved"
    assert digest(json_file) == original[1]
    run(f"cp {yaml_file} nix/role/test/next.enc.yaml")
    system = client.succeed("readlink -f /run/current-system").strip()
    client.succeed(f"{system}/specialisation/updated/bin/switch-to-configuration test")
    client.wait_for_open_port(8443)
    client.wait_until_succeeds(f'test "$(systemctl show -p InvocationID --value certificate-consumer.service)" != "{invocation}"')
    run("curl --fail --cacert .data/issuer.pem https://first.test:8443/")
    assert client.succeed("cat /run/secrets/a_cert") == selected["a_cert"]
    run("idr-update-certs")
    renewed = decrypt(yaml_file)
    assert renewed["a_cert"] == selected["a_cert"]
    assert renewed["b_cert"] != before["b_cert"]

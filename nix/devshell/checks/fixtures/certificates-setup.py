import json
import shlex


def operator(command):
    return machine.succeed(
        "su - operator -c " + shlex.quote("cd project && " + command), timeout=900
    )


def prepare_certificates(role_module):
    start_all()
    machine.wait_for_unit("sshd.service")
    machine.wait_for_unit("nginx.service")
    machine.wait_for_unit("pebble.service")
    machine.wait_for_open_port(14000)
    operator("nix flake update team")
    operator("direnv allow")
    operator("direnv exec . idr-mk-role tls </dev/null")
    role = "tls-" + json.loads(operator("cat nix/role/tls/meta.json"))["id"]
    operator(
        "sed -i '/networking.hostName =/a\\      idr.roles.\""
        + role
        + "\".enable = true;' nix/machine/test-machine/configuration.nix"
    )
    operator(
        "direnv exec . bash -euo pipefail <<'COMMANDS'\n"
        "printf '%s' '{\"application_token\":\"synthetic application value\"}' | "
        "sops encrypt --input-type json --output-type yaml "
        "--filename-override nix/role/tls/certs.enc.yaml /dev/stdin > nix/role/tls/certs.enc.yaml\n"
        "printf '%s' '{}' | sops encrypt --input-type json --output-type json "
        "--filename-override nix/role/tls/certs.enc.json /dev/stdin > nix/role/tls/certs.enc.json\n"
        "COMMANDS"
    )
    operator("cp " + shlex.quote(role_module) + " nix/role/tls/flake-module.nix")
    operator("git add nix/role/tls")


def decrypt(path):
    # The caller receives only certificate metadata or hashes, never private keys.
    # Assertions must not reenter the shell: its startup writes rotation metadata.
    command = (
        'SOPS_AGE_KEY_FILE="$HOME/.config/idr/operator.age" '
        f"sops decrypt --output-type json {shlex.quote(path)} | "
        """jq 'with_entries(select(.key | endswith("_cert_key") or endswith("_cert_pem") | not))' """
        "> /tmp/certificate-metadata.json"
    )
    operator("bash -euo pipefail -c " + shlex.quote(command))
    return json.loads(operator("cat /tmp/certificate-metadata.json"))

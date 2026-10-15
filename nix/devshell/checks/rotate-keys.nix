top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    snapshot = pkgs.writeText "secret-hashes.py" ''
      import hashlib
      import json
      import subprocess
      from pathlib import Path

      result = {}
      files = {
          "machine": ("nix/machine/test-machine/secrets.enc.json", [
              "ssh_host_ed25519_key", "initrd_ssh_host_ed25519_key", "root_password", "api_token",
          ]),
          "disk": ("nix/machine/test-machine/disk-key.enc.json", ["disk_key"]),
          "role": ("nix/role/some-role/secrets.enc.json", ["api_token"]),
      }
      for kind, (path, fields) in files.items():
          decrypted = json.loads(subprocess.check_output(["sops", "decrypt", path]))
          for field in ("ssh_host_ed25519_key", "initrd_ssh_host_ed25519_key"):
              if field in decrypted:
                  assert decrypted[field].startswith("-----BEGIN OPENSSH PRIVATE KEY-----")
                  public = subprocess.check_output(["ssh-keygen", "-y", "-P", "", "-f", "/dev/stdin"], input=decrypted[field].encode())
                  assert public.decode().split()[:2] == decrypted[field + "_pub_unencrypted"].split()[:2]
          result[kind] = {
              field: hashlib.sha256(decrypted[field].encode()).hexdigest()
              for field in fields
          }
      encrypted_role = json.loads(Path(files["role"][0]).read_text())
      result["role"]["ciphertext"] = hashlib.sha256(encrypted_role["api_token"].encode()).hexdigest()
      print(json.dumps(result))
    '';
  in {
    checks.rotate-keys = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
      machineId = top.self.nixosConfigurations."example-${system}".config.idr.preset.base.id;
      editSecret = config.node.pkgs.writeShellScript "add-application-token" ''
        set -eu
        ${lib.getExe config.node.pkgs.jq} --slurpfile application "$HOME/.config/idr/application.json" \
          '. + $application[0]' "$1" > "$1.new"
        mv "$1.new" "$1"
      '';
    in {
      imports =
        (with top.self.modules.nixosTest; [base operator ssh-git])
        ++ [
          (lib.modules.importApply ./fixtures/operator-project.nix {
            inherit project machineId;
            extraSetup = ''
              printf '{"api_token":"%s"}\n' "$(head -c 32 /dev/urandom | base64)" > .config/idr/application.json
            '';
          })
        ];

      name = "rotate-keys";
      globalTimeout = 25 * 60;
      idr.test.storePaths = [top.self.packages.${system}.default];
      defaults = {pkgs, ...}: {
        environment.systemPackages = [pkgs.python3];
        environment.variables.SOPS_EDITOR = toString editSecret;
      };
      containers = lib.optionalAttrs isLinux {machine = {};};
      nodes = lib.optionalAttrs (!isLinux) {
        machine = {
          virtualisation = {
            memorySize = 8192;
            cores = 8;
          };
          networking.useDHCP = false;
        };
      };

      testScript = ''
        import json
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("sshd.service")

        with subtest("enroll an operator and enable a role on the machine"):
            operator("nix flake update team")
            operator("direnv allow")
            operator("direnv exec . idr-mk-role some-role </dev/null")
            role = "some-role-" + json.loads(operator("cat nix/role/some-role/meta.json"))["id"]
            operator(
                "sed -i '/networking.hostName =/a\\      idr.roles.\"" + role
                + "\".enable = true;' nix/machine/test-machine/configuration.nix"
            )
            operator("test ! -e .data/machine-host-key/test-machine")

        def check_host_access(identity):
            paths = operator("printf '%s\\n' nix/machine/test-machine/*.enc.json nix/role/some-role/secrets.enc.json").splitlines()
            for path in paths:
                command = (
                    "direnv exec . env -u SOPS_AGE_KEY_CMD "
                    "SOPS_AGE_KEY_FILE=\"$HOME\"/.config/idr/" + identity + ".age "
                    "sops decrypt --output /dev/null " + shlex.quote(path)
                )
                operator(command)

        def save_host_identity(identity):
            operator("direnv exec . bash -euo pipefail -c " + shlex.quote(
                "sops decrypt --extract '[\"ssh_host_ed25519_key\"]' "
                "nix/machine/test-machine/secrets.enc.json | ssh-to-age -private-key "
                "> ~/.config/idr/" + identity + ".age"
            ))

        with subtest("prepare application credentials and prove the original host access"):
            operator("direnv exec . sops nix/machine/test-machine/secrets.enc.json")
            operator("direnv exec . sops nix/role/some-role/secrets.enc.json")
            operator("git add nix/machine/test-machine/secrets.enc.json nix/role/some-role/secrets.enc.json")
            save_host_identity("old-host")
            check_host_access("old-host")

        with subtest("rotate all managed keys and verify access and idempotence before reentry"):
            # Capture both sides of the actual rotation before startup can update metadata.
            operator(
                "direnv exec . bash -euo pipefail <<'COMMANDS'\n"
                "python ${snapshot} > /tmp/rotation-before.json\n"
                "mkdir -m 0700 /tmp/idr-keygen-tmp\n"
                "TMPDIR=/tmp/idr-keygen-tmp idr-rotate-keys --force test-machine\n"
                "test -z \"$(ls -A /tmp/idr-keygen-tmp)\"\n"
                "python ${snapshot} > /tmp/rotation-after.json\n"
                "sops decrypt --extract '[\"ssh_host_ed25519_key\"]' "
                "nix/machine/test-machine/secrets.enc.json | ssh-to-age -private-key > ~/.config/idr/new-host.age\n"
                "for file in nix/machine/test-machine/*.enc.json nix/role/some-role/secrets.enc.json; do\n"
                "  env -u SOPS_AGE_KEY_CMD SOPS_AGE_KEY_FILE=\"$HOME\"/.config/idr/new-host.age "
                "sops decrypt --output /dev/null \"$file\"\n"
                "  if env -u SOPS_AGE_KEY_CMD SOPS_AGE_KEY_FILE=\"$HOME\"/.config/idr/old-host.age "
                "sops decrypt --output /dev/null \"$file\" >/dev/null 2>&1; then\n"
                "    echo \"Old host identity still decrypts $file\" >&2; exit 1\n"
                "  fi\n"
                "done\n"
                "sha256sum nix/machine/test-machine/*.enc.json nix/role/some-role/secrets.enc.json > /tmp/rotated.sha256\n"
                "idr-rotate-keys test-machine\n"
                "sha256sum --check /tmp/rotated.sha256\n"
                "COMMANDS"
            )

        with subtest("reenter the devshell without rewriting rotated secrets"):
            operator("direnv exec . sha256sum --check /tmp/rotated.sha256")

        with subtest("managed secrets change while machine and role application credentials keep their values"):
            before = json.loads(operator("cat /tmp/rotation-before.json"))
            after = json.loads(operator("cat /tmp/rotation-after.json"))
            for field in ["ssh_host_ed25519_key", "initrd_ssh_host_ed25519_key", "root_password"]:
                assert after["machine"][field] != before["machine"][field], field
            assert after["disk"]["disk_key"] != before["disk"]["disk_key"]
            assert after["machine"]["api_token"] == before["machine"]["api_token"]
            assert after["role"]["api_token"] == before["role"]["api_token"]
            assert after["role"]["ciphertext"] != before["role"]["ciphertext"]
      '';
    });
  };
}

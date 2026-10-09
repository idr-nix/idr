top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    mkCheck = {
      name,
      corrupt ? false,
      extraSetup ? "",
      afterSetup ? "",
      testScript,
    }:
      pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (pkgs.stdenv.hostPlatform) isLinux;
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        machineId = top.self.nixosConfigurations."example-${system}".config.idr.preset.base.id;
        shell =
          if corrupt
          then "nix develop -c"
          else "direnv exec .";
      in {
        imports =
          (with top.self.modules.nixosTest; [base operator ssh-git])
          ++ [
            (lib.modules.importApply ./fixtures/operator-project.nix {
              inherit project machineId;
              extraSetup =
                ''
                  # All identities and plaintext in these tests are synthetic.
                  ssh-to-age -private-key -i project/.data/machine-host-key/test-machine > .config/idr/bootstrap.age
                  SOPS_AGE_KEY_FILE="$PWD/.config/idr/bootstrap.age" \
                    sops set project/nix/machine/test-machine/secrets.enc.json '["access_test"]' '"accessible"'
                ''
                + extraSetup;
            })
          ];

        inherit name;
        globalTimeout = 20 * 60;
        idr.test.storePaths = [top.self.packages.${system}.default];
        defaults = {pkgs, ...}: {
          systemd.services.idr-operator-fixture = {
            path = [pkgs.sops];
            script = lib.mkAfter afterSetup;
          };
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

        testScript =
          ''
            import shlex

            def operator(command):
                return machine.succeed(
                    "su - operator -c " + shlex.quote("cd project && " + command),
                    timeout=900,
                )

            # Cached direnv entries rerun startup and retry pending secret updates.
            # Corruption separately tests nix develop's successful entry despite hook errors.
            def enter(name, command="true"):
                log = "/tmp/" + name + ".log"
                operator("${shell} bash -euc " + shlex.quote(command) + " > " + log + " 2>&1")
                output = operator("cat " + log)
                for message in ["Failed to get the data key", "Could not decrypt", "Error: nu::", "failed to load age identities"]:
                    assert message not in output, (name, message)

            start_all()
            machine.wait_for_unit("sshd.service")
            operator("nix flake update team")
            ${lib.optionalString (!corrupt) ''
              operator("direnv allow")
            ''}
          ''
          + testScript;
      });
  in {
    checks = {
      devshell-partial-secret-access = mkCheck {
        name = "devshell-partial-secret-access";
        extraSetup = ''
          age-keygen -o .config/idr/restricted.age >/dev/null 2>&1
          restricted_recipient=$(age-keygen -y .config/idr/restricted.age)
          operator_recipient=$(cat .config/idr/operator.age.pub)
          mkdir -p project/nix/machine/restricted project/nix/role/restricted project/nix/checks/fixtures/access
          for file in nix/machine/restricted/secrets.enc.json nix/role/restricted/secrets.enc.yaml; do
            printf '{"token":"restricted test value"}' | \
              sops --config /dev/null encrypt --age "$restricted_recipient" --input-type json \
                --filename-override "$file" > "project/$file"
          done
          # This file already has rotation metadata, so only updatekeys needs retrying.
          printf '{"token":"fixture test value","token@_unencrypted":"interval=90day modified_ts=1"}' | \
            sops --config /dev/null encrypt --age "$restricted_recipient" --input-type json \
              --filename-override secrets.enc.json > project/nix/checks/fixtures/access/secrets.enc.json

          mkdir -p project/nix/access-policy
          cat > project/nix/access-policy/flake-module.nix <<EOF
          _: _: {
            idr.sops.creation_rules = [{
              priority = 100;
              rule = {
                path_regex = "^nix/(machine/restricted|role/restricted|checks/fixtures/access)/";
                age = "$operator_recipient";
              };
            }];
          }
          EOF
        '';
        # Leave plaintext candidates untracked after the fixture stages encrypted files.
        afterSetup = ''
          printf '{}' > project/nix/machine/restricted/placeholder.enc.json
          printf '%s' '{"token":"synthetic plaintext"}' > project/nix/machine/restricted/plaintext.enc.json
          printf 'token: synthetic plaintext\n' > project/nix/role/restricted/plaintext.enc.yaml
        '';
        testScript = ''
          import json

          restricted_paths = [
              "nix/machine/restricted/secrets.enc.json",
              "nix/role/restricted/secrets.enc.yaml",
              "nix/checks/fixtures/access/secrets.enc.json",
          ]
          restricted = shlex.join(restricted_paths)
          machine_secret = "nix/machine/test-machine/secrets.enc.json"
          plaintext = [
              "nix/machine/restricted/placeholder.enc.json",
              "nix/machine/restricted/plaintext.enc.json",
              "nix/role/restricted/plaintext.enc.yaml",
          ]

          def pending(queue):
              return json.loads(operator("if test -e .data/" + queue + "; then cat .data/" + queue + "; else echo '[]'; fi"))

          def untouched_plaintext():
              operator("sha256sum --check /tmp/plaintext.sha256")
              assert not operator("git ls-files -- " + shlex.join(plaintext)).strip(), "Plaintext was auto-staged"
              for queue in ["pending-sops-updatekeys.json", "pending-rotation-files.json"]:
                  assert not set(plaintext).intersection(pending(queue)), (queue, "Plaintext was queued")

          with subtest("enter a project with access to only some encrypted files"):
              operator("sha256sum " + restricted + " > /tmp/restricted.sha256")
              operator("sha256sum " + shlex.join(plaintext) + " > /tmp/plaintext.sha256")
              enter("partial-access", "sops decrypt --output /dev/null " + machine_secret)
              operator("sha256sum --check /tmp/restricted.sha256")
              assert set(restricted_paths).issubset(pending("pending-sops-updatekeys.json"))
              assert set(restricted_paths[:2]).issubset(pending("pending-rotation-files.json"))
              operator("jq -e 'has(\"access_test@_unencrypted\")' " + machine_secret)
              operator(
                  "jq -e --arg recipient \"$(cat ~/.config/idr/operator.age.pub)\" "
                  "'any(.sops.age[]; .recipient == $recipient)' " + machine_secret
              )

          with subtest("leave plaintext secret candidates unchanged on first entry"):
              untouched_plaintext()

          with subtest("repeat shell entry quietly while explicit decryption still fails"):
              enter(
                  "partial-access-repeat",
                  "if sops decrypt --output /dev/null nix/machine/restricted/secrets.enc.json "
                  ">/tmp/explicit-decrypt.log 2>&1; then exit 1; fi; "
                  "grep -q 'Failed to get the data key' /tmp/explicit-decrypt.log",
              )
              operator("sha256sum --check /tmp/restricted.sha256")
              assert set(restricted_paths).issubset(pending("pending-sops-updatekeys.json"))
              assert set(restricted_paths[:2]).issubset(pending("pending-rotation-files.json"))

          with subtest("leave plaintext secret candidates unchanged on repeated entry"):
              untouched_plaintext()

          with subtest("retry skipped files after the missing identity becomes available"):
              operator("printf '\\nSOPS_AGE_KEY_FILE=/home/operator/.config/idr/restricted.age\\n' >> .env")
              enter("access-restored", "for file in " + restricted + "; do sops decrypt --output /dev/null \"$file\"; done")
              operator("jq -e 'has(\"token@_unencrypted\")' nix/machine/restricted/secrets.enc.json")
              operator("grep -q '^token@_unencrypted:' nix/role/restricted/secrets.enc.yaml")
              for path in ["nix/machine/restricted/secrets.enc.json", "nix/checks/fixtures/access/secrets.enc.json"]:
                  operator(
                      "jq -e --arg recipient \"$(cat ~/.config/idr/operator.age.pub)\" "
                      "'any(.sops.age[]; .recipient == $recipient)' " + path
                  )
              for queue in ["pending-sops-updatekeys.json", "pending-rotation-files.json"]:
                  assert not set(restricted_paths).intersection(pending(queue)), queue
              operator("sha256sum " + restricted + " > /tmp/restored.sha256")
              operator("sed -i '/^SOPS_AGE_KEY_FILE=/d' .env")
              enter("operator-only", "for file in " + restricted + "; do sops decrypt --output /dev/null \"$file\"; done")
              operator("sha256sum --check /tmp/restored.sha256")

        '';
      };
      devshell-corrupt-secrets = mkCheck {
        name = "devshell-corrupt-secrets";
        corrupt = true;
        testScript = ''
          machine_secret = "nix/machine/test-machine/secrets.enc.json"

          with subtest("start with an accessible encrypted file"):
              enter("corruption-accessible", "sops decrypt --output /dev/null " + machine_secret)

          with subtest("report corruption instead of mistaking it for missing access"):
              operator(
                  "jq '. + {broken: \"ENC[AES256_GCM,data:invalid]\"}' " + machine_secret
                  + " > /tmp/corrupt.json && cp /tmp/corrupt.json " + machine_secret
              )
              operator("nix develop -c true > /tmp/corrupt-entry.log 2>&1")
              output = operator("cat /tmp/corrupt-entry.log")
              assert "Could not decrypt" in output, "Corrupt ciphertext was silently ignored"
              operator("cmp /tmp/corrupt.json " + machine_secret)
        '';
      };
    };
  };
}

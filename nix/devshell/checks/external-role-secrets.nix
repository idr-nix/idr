top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    configChecks = config.checks;
    mkCheck = prepared:
      pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (pkgs.stdenv.hostPlatform) isLinux;
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        machineId = top.self.nixosConfigurations."example-${system}".config.idr.preset.base.id;
        project =
          if prepared
          then configChecks.external-role-secrets
          else configChecks.mk-project;
        editSecret = config.node.pkgs.writeShellScript "edit-role-secret" ''
          printf '%s\n' '{"api_token":"public cross-repository test token"}' > "$1"
        '';
      in {
        imports = [
          (lib.modules.importApply ./fixtures/external-role-project.nix {
            inherit top project machineId prepared;
          })
        ];

        name =
          if prepared
          then "external-role-key-rotation"
          else "external-role-secrets";
        globalTimeout = 30 * 60;
        idr.test.storePaths = [top.self.packages.${system}.default];
        defaults.environment.variables.SOPS_EDITOR = toString editSecret;
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
            import json
            import shlex

            def operator(command, repository="project"):
                return machine.succeed(
                    "su - operator -c " + shlex.quote("cd " + repository + " && " + command),
                    timeout=900,
                )

            def publish(repository, message):
                operator("git add -A && git commit -qm " + shlex.quote(message) + " && git push", repository)

            def update_application():
                operator("nix flake update team", "application")
                operator("nix develop -c true", "application")
                publish("application", "Update role secret recipients")
                operator("nix flake update application")

            def role_secret():
                return operator(
                    "nix eval --raw .#nixosConfigurations.test-machine.config.sops.secrets.api-token.sopsFile"
                ).strip()

            def save_host_identity(name):
                operator(
                    "nix develop -c bash -euo pipefail <<'COMMANDS'\n"
                    "sops decrypt --extract '[\"ssh_host_ed25519_key\"]' "
                    "nix/machine/test-machine/secrets.enc.json | ssh-to-age -private-key "
                    "> ~/.config/idr/" + name + ".age\n"
                    "COMMANDS"
                )

            def assert_host_access(name, allowed):
                decrypt = (
                    "env -u SOPS_AGE_KEY_CMD SOPS_AGE_KEY_FILE=$HOME/.config/idr/" + name + ".age "
                    "sops decrypt --extract '[\"api_token\"]' " + shlex.quote(role_secret())
                )
                if allowed:
                    command = "test \"$(" + decrypt + ")\" = 'public cross-repository test token'"
                else:
                    command = "if " + decrypt + " >/dev/null 2>&1; then exit 1; fi"
                operator("nix develop -c bash -ec " + shlex.quote(command))

            start_all()
            machine.wait_for_unit("sshd.service")

          ''
          + (
            if prepared
            then ''
              with subtest("restore the verified external role grant"):
                  public_key = json.loads(operator("cat nix/machine/test-machine/secrets.enc.json"))["ssh_host_ed25519_key_age_pub_unencrypted"]
                  assert_host_access("old-host", True)
              with subtest("update the shared machine entry after SSH host key rotation"):
                  operator("nix develop -c idr-rotate-keys --force test-machine")
                  save_host_identity("new-host")
                  assert_host_access("new-host", False)
                  rotated_key = json.loads(operator("cat nix/machine/test-machine/secrets.enc.json"))["ssh_host_ed25519_key_age_pub_unencrypted"]
                  assert rotated_key != public_key
                  operator("sed -i 's/" + public_key + "/" + rotated_key + "/' team.toml", "team-work")
                  publish("team-work", "Publish the rotated machine age recipient")
                  update_application()
                  assert_host_access("new-host", True)
                  assert_host_access("old-host", False)
            ''
            else ''
              with subtest("create and publish a role in the separate application repository"):
                  operator(
                      "git clone ssh://git@github.com/myorg/team team-work && "
                      "git clone ssh://git@github.com/myorg/application application && "
                      "cp project/.env application/.env",
                      ".",
                  )
                  operator("nix flake update team")
                  operator("nix flake update team", "application")
                  operator("nix develop -c idr-mk-role some-role </dev/null", "application")
                  role = "some-role-" + json.loads(operator("cat nix/role/some-role/meta.json", "application"))["id"]
                  operator(
                      "sed -i 's|groups = .*|groups = [\"host-test-machine-${machineId}\", \"role-" + role + "\"]|' team.toml",
                      "team-work",
                  )
                  publish("team-work", "Give the operator access to the application role")
                  operator("nix flake update team", "application")
                  operator("nix develop -c sops nix/role/some-role/secrets.enc.json", "application")
                  operator(
                      "sed -i 's|lib.mkIf cfg.enable {}|lib.mkIf cfg.enable { "
                      "environment.etc.role-message.text = \"external role enabled\"; "
                      "idr.secrets-source.api-token = { sopsFile = ./secrets.enc.json; key = \"api_token\"; }; "
                      "sops.secrets.api-token.format = \"json\"; }|' nix/role/some-role/nixos-module.nix",
                      "application",
                  )
                  publish("application", "Export the application role and its encrypted secret")

              with subtest("add the application input, import its modules, and enable its role"):
                  operator(
                      "sed -i '/^  inputs = {/a\\    application.url = \"git+ssh://git@github.com/myorg/application\";' flake.nix && "
                      "sed -i 's|(builtins.attrValues top.inputs.self.modules.nixos)|"
                      "(builtins.attrValues top.inputs.self.modules.nixos) ++ "
                      "(builtins.attrValues top.inputs.application.modules.nixos)|' nix/machine/test-machine/configuration.nix && "
                      "nix flake update application"
                  )
                  enabled = "nix eval --json .#nixosConfigurations.test-machine.config.idr.roles." + shlex.quote('"' + role + '"') + ".enable"
                  assert json.loads(operator(enabled)) is False
                  operator(
                      "sed -i '/networking.hostName =/a\\      idr.roles.\"" + role
                      + "\".enable = true;' nix/machine/test-machine/configuration.nix"
                  )
                  assert json.loads(operator(enabled)) is True
                  assert operator("nix eval --raw .#nixosConfigurations.test-machine.config.environment.etc.role-message.text") == "external role enabled"
                  save_host_identity("old-host")
                  assert_host_access("old-host", False)

              with subtest("publish external machine membership and update both repository inputs"):
                  public_key = json.loads(operator("cat nix/machine/test-machine/secrets.enc.json"))["ssh_host_ed25519_key_age_pub_unencrypted"]
                  member = (
                      '\n["test-machine-${machineId}"]\nsystem = true\nagePublicKey = "' + public_key
                      + '"\ngroups = ["role-' + role + '"]\n'
                  )
                  operator("printf %s " + shlex.quote(member) + " >> team.toml", "team-work")
                  publish("team-work", "Grant the external machine access to the role")
                  update_application()
                  assert_host_access("old-host", True)

              with subtest("export the verified repositories and synthetic identities"):
                  # Keep Git history and remote-tracking refs for subsequent pushes.
                  # Omit shell caches and SSH known hosts, which belong to this node.
                  machine.succeed(
                      "bash -o pipefail -c " + shlex.quote(
                          "tar -C / --exclude=home/operator/project/.data "
                          "--exclude=home/operator/application/.data "
                          "--exclude=home/operator/.ssh/known_hosts* "
                          "--sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner "
                          "-c home/operator/project home/operator/application home/operator/team-work "
                          "home/operator/.config/idr home/operator/.ssh/id_ed25519 "
                          "home/operator/.ssh/id_ed25519.pub var/lib/ssh-git/repositories "
                          "> /tmp/external-role-project.tar"
                      ),
                      timeout=600,
                  )
                  machine.copy_from_machine("/tmp/external-role-project.tar")
            ''
          );
      });
  in {
    checks = {
      external-role-secrets = mkCheck false;
      external-role-key-rotation = mkCheck true;
    };
  };
}

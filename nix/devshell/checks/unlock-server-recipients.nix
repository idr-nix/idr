top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks.unlock-server-recipients = pkgs.testers.runNixOSTest ({config, ...}: let
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
        (with top.self.modules.nixosTest; [nix nix-store operator ssh-git])
        ++ [
          (lib.modules.importApply ./fixtures/operator-project.nix {
            inherit project machineId;
            extraSetup = ''
              ssh-keygen -q -t ed25519 -N "" -f .config/idr/unlock-server-ssh
              ssh-to-age -i .config/idr/unlock-server-ssh -private-key > .config/idr/unlock-server.age
              ssh-to-age < .config/idr/unlock-server-ssh.pub > .config/idr/unlock-server.age.pub
              cat >> team/team.toml <<EOF
              ["unlock-server-123456abcdef"]
              system = true
              groups = ["unlock-server"]
              hostname = "192.0.2.40"
              port = 64998
              sshPublicKey = "$(cat .config/idr/unlock-server-ssh.pub)"
              agePublicKey = "$(cat .config/idr/unlock-server.age.pub)"
              EOF
              printf '{"api_token":"%s"}\n' "$(head -c 32 /dev/urandom | base64)" > .config/idr/application.json
            '';
          })
        ];

      name = "unlock-server-recipients";
      globalTimeout = 20 * 60;
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

        with subtest("update team membership and enter the shell to grant disk-key access"):
            operator("nix flake update team")
            operator("nix develop -c idr-mk-role some-role </dev/null")
            role = "some-role-" + json.loads(operator("cat nix/role/some-role/meta.json"))["id"]
            operator(
                "sed -i '/networking.hostName =/a\\      idr.roles.\"" + role
                + "\".enable = true;' nix/machine/test-machine/configuration.nix"
            )

        with subtest("the operator can decrypt all secrets while the unlock server can decrypt only the disk key"):
            operator(
                "nix develop -c bash -eu <<'COMMANDS'\n"
                "sops nix/role/some-role/secrets.enc.json\n"
                "git add nix/role/some-role/secrets.enc.json\n"
                "test ! -e .data/machine-host-key/test-machine\n"
                "for file in nix/machine/test-machine/*.enc.json nix/role/some-role/secrets.enc.json; do\n"
                "  sops decrypt --output /dev/null \"$file\"\n"
                "done\n"
                "unset SOPS_AGE_KEY_CMD\n"
                "export SOPS_AGE_KEY_FILE=$HOME/.config/idr/unlock-server.age\n"
                "sops decrypt --output /dev/null nix/machine/test-machine/disk-key.enc.json\n"
                "for file in nix/machine/test-machine/secrets.enc.json nix/role/some-role/secrets.enc.json; do\n"
                "  if sops decrypt --output /dev/null \"$file\" >/dev/null 2>&1; then\n"
                "    echo \"Unlock server unexpectedly decrypts $file\" >&2; exit 1\n"
                "  fi\n"
                "done\n"
                "COMMANDS"
            )
      '';
    });
  };
}

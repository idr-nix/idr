{
  project,
  machineId,
  user ? "operator",
  homeDirectory ? "/home/${user}",
  projectDirectory ? "project",
  ageKeyFile ? "operator.age",
  extraSetup ? "",
}: {lib, ...}: let
  projectPath = lib.escapeShellArg projectDirectory;
in {
  idr.test.sshGit = {
    clientUser = user;
    repositories = [
      {
        source = "${homeDirectory}/team";
        url = "git+ssh://git@github.com/myorg/team";
      }
    ];
  };

  defaults = {pkgs, ...}: {
    environment.systemPackages = [pkgs.jq];
    systemd.services.idr-operator-fixture = {
      description = "Prepare operator keys, team membership, and the project archive";
      requiredBy = ["ssh-git-fixture.service"];
      before = ["ssh-git-fixture.service"];
      after = ["systemd-tmpfiles-setup.service"];
      path = with pkgs; [coreutils gnutar gnused gitMinimal openssh ssh-to-age age];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = user;
        WorkingDirectory = homeDirectory;
      };
      script = ''
        umask 077
        mkdir -p .config/idr team
        ssh-keygen -q -t ed25519 -N "" -f .config/idr/operator-ssh
        ssh-to-age -i .config/idr/operator-ssh -private-key > .config/idr/operator.age
        ssh-to-age < .config/idr/operator-ssh.pub > .config/idr/operator.age.pub
        age-keygen -o .config/idr/wrong.age >/dev/null 2>&1

        cat > team/team.toml <<EOF
        [John]
        mail = "john@example.invalid"
        sshPublicKey = "$(cat .config/idr/operator-ssh.pub)"
        agePublicKey = "$(cat .config/idr/operator.age.pub)"
        groups = ["host-test-machine-${machineId}"]
        EOF

        mkdir -p ${projectPath}
        tar --strip-components=1 -C ${projectPath} -xf ${project}/project.tar
        sed -i 's|file+file:///dev/null|git+ssh://git@github.com/myorg/team|' ${projectPath}/flake.nix
        cat > ${projectPath}/.env <<'EOF'
        IDR_USER=John
        IDR_SOPS_AGE_KEY_CMD='open --raw ${homeDirectory}/.config/idr/${ageKeyFile}'
        EOF
        ${extraSetup}
        git -C ${projectPath} init -q
        git -C ${projectPath} add -A
      '';
    };
  };
}

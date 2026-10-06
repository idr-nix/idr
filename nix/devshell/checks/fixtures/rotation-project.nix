{
  top,
  project,
  system,
  rotated ? false,
}: {
  hostPkgs,
  lib,
  ...
}: let
  machineId = top.self.nixosConfigurations."example-${system}".config.idr.preset.base.id;
  projectDirectory =
    if hostPkgs.stdenv.hostPlatform.isDarwin
    then "/run/idr-project-archive"
    else toString project;
in {
  imports =
    [
      top.self.modules.nixosTest.ssh-git
      (lib.modules.importApply ../local-vm-fixture.nix {
        inherit top project system;
        restoreProject = false;
      })
    ]
    ++ lib.optional (!rotated) (lib.modules.importApply ./operator-project.nix {
      inherit machineId;
      project = projectDirectory;
      user = "root";
      homeDirectory = "/root";
    });

  idr.test.sshGit = lib.mkIf rotated {
    clientUser = "root";
    repositories = [
      {
        source = "/root/team";
        url = "git+ssh://git@github.com/myorg/team";
      }
    ];
  };

  defaults = {pkgs, ...}: {
    systemd.services = {
      idr-project-fixture = {
        after = ["idr-operator-fixture.service"];
        requires = ["idr-operator-fixture.service"];
      };
      idr-operator-fixture = lib.mkIf rotated {
        description = "Restore the rotated VM and its synthetic operator identity";
        requiredBy = ["ssh-git-fixture.service"];
        before = ["ssh-git-fixture.service"];
        after = ["systemd-tmpfiles-setup.service"];
        path = [pkgs.gnutar pkgs.gitMinimal];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          WorkingDirectory = "/root";
        };
        # Everything in this archive is generated inside the test, including its public fixture keys.
        script = ''
          umask 077
          tar --no-same-owner -xf ${projectDirectory}/rotation-project.tar
          git -C project init -q
          git -C project add -A
        '';
      };
    };
  };
}

_: {
  config,
  lib,
  ...
}: let
  cfg = config.idr.test.sshGit;
  urlPattern = "(git\\+)?ssh://git@([a-zA-Z0-9._-]+)(/[a-zA-Z0-9._~/-]+)";
  repositories = lib.imap0 (index: repository: let
    parts = builtins.match urlPattern repository.url;
  in
    repository
    // {
      host = builtins.elemAt parts 1;
      path = builtins.elemAt parts 2;
      directory = "/var/lib/ssh-git/repositories/${toString index}";
      worktree = "/tmp/ssh-git-${toString index}";
    })
  cfg.repositories;
in {
  options.idr.test.sshGit = {
    repositories = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.path;
            description = "Source directory to commit and serve as a Git repository.";
          };
          writable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Allow the test client to push updates to this repository over SSH.";
          };
          url = lib.mkOption {
            type = lib.types.strMatching urlPattern;
            example = "git+ssh://git@github.com/myorg/team";
            description = ''
              SSH Git URL to serve locally, with optional git+ prefix and user git.
              Repository paths must be unique across hosts. Explicit ports, query
              strings, fragments, and escaped path characters are not supported.
            '';
          };
        };
      });
      default = [];
      description = "Git repositories made available over SSH inside each test node.";
    };
    clientUser = lib.mkOption {
      type = lib.types.str;
      default = "operator";
      description = "Existing test user whose SSH key can read the fixture repositories.";
    };
  };

  config = lib.mkIf (repositories != []) {
    defaults = {
      config,
      pkgs,
      ...
    }: let
      client = config.users.users.${cfg.clientUser};
      uploadPack = pkgs.writeShellScript "ssh-git-upload-pack" ''
        case "''${SSH_ORIGINAL_COMMAND:-}" in
          ${lib.concatMapStringsSep "\n" (repository: ''
            ${lib.escapeShellArg "git-upload-pack '${repository.path}'"})
              exec ${lib.getExe' pkgs.gitMinimal "git-upload-pack"} ${lib.escapeShellArg repository.directory}
              ;;
            ${lib.optionalString repository.writable ''
              ${lib.escapeShellArg "git-receive-pack '${repository.path}'"})
                exec ${lib.getExe' pkgs.gitMinimal "git-receive-pack"} ${lib.escapeShellArg repository.directory}
                ;;
            ''}
          '')
          repositories}
          *)
            echo "Unsupported Git command or repository" >&2
            exit 1
            ;;
        esac
      '';
    in {
      assertions = [
        {
          assertion = lib.length repositories == lib.length (lib.unique (map (repository: repository.path) repositories));
          message = "idr.test.sshGit.repositories must have unique paths, including across different hosts.";
        }
      ];

      services.openssh = {
        enable = true;
        startWhenNeeded = false;
        authorizedKeysFiles = ["/var/lib/ssh-git/authorized_keys"];
        authorizedKeysInHomedir = false;
        settings = {
          AllowUsers = ["git"];
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          ForceCommand = toString uploadPack;
          DisableForwarding = true;
          PermitTTY = false;
          PermitUserRC = false;
          LogLevel = "VERBOSE";
        };
      };
      programs.ssh.extraConfig = lib.concatMapStringsSep "\n" (host: ''
        Host ${host}
          HostName 127.0.0.1
          HostKeyAlias ${host}
          HostKeyAlgorithms ssh-ed25519
          IdentityFile ${client.home}/.ssh/id_ed25519
          IdentitiesOnly yes
          StrictHostKeyChecking accept-new
      '') (lib.unique (map (repository: repository.host) repositories));

      users.groups.git = {};
      users.users.git = {
        isSystemUser = true;
        group = "git";
        home = "/var/lib/ssh-git";
        hashedPassword = "*";
        shell = lib.getExe pkgs.bashInteractive;
      };
      systemd.tmpfiles.rules = [
        "d /var/lib/ssh-git 0755 root root -"
        "d /var/lib/ssh-git/repositories 0755 root root -"
        "f /var/lib/ssh-git/authorized_keys 0644 root root -"
        "d ${client.home}/.ssh 0700 ${cfg.clientUser} ${client.group} -"
      ];
      systemd.services.ssh-git-fixture = {
        description = "Prepare the local SSH Git repositories";
        requiredBy = ["sshd.service"];
        before = ["sshd.service"];
        after = ["systemd-tmpfiles-setup.service"];
        path = [pkgs.coreutils pkgs.gitMinimal pkgs.openssh];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script =
          lib.concatMapStringsSep "\n" (repository: ''
            cp -r --no-preserve=mode ${lib.escapeShellArg repository.source} ${repository.worktree}
            git -C ${repository.worktree} init -q -b main
            git -C ${repository.worktree} add -A
            git -C ${repository.worktree} -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm fixture
            git clone -q --bare --no-hardlinks ${repository.worktree} ${repository.directory}
            ${lib.optionalString repository.writable ''
              chown -R git:git ${repository.directory}
            ''}
          '')
          repositories
          + ''
            ssh-keygen -q -t ed25519 -N "" -f ${lib.escapeShellArg "${client.home}/.ssh/id_ed25519"}
            chown ${lib.escapeShellArg "${cfg.clientUser}:${client.group}"} ${lib.escapeShellArg "${client.home}/.ssh/id_ed25519"} ${lib.escapeShellArg "${client.home}/.ssh/id_ed25519.pub"}
            cat ${lib.escapeShellArg "${client.home}/.ssh/id_ed25519.pub"} > /var/lib/ssh-git/authorized_keys
          '';
      };
    };

    containerDefaults = {
      # Explicit includes require files owned inside the container's user namespace.
      environment.etc."ssh/ssh_config".mode = "0644";
      programs.ssh.systemd-ssh-proxy.enable = false;
    };
  };
}

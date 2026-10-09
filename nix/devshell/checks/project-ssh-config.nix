top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    sshModule = pkgs.writeText "project-ssh-flake-module.nix" ''
      _: {
        perSystem = {
          devshells.default.idr.sshConfig = '''
            Host build-host
              HostName 127.0.0.1
              User deploy
              Port 2222
          ''';
        };
      }
    '';
    userConfig = pkgs.writeText "operator-ssh-config" ''
      Host build-host
        HostName 192.0.2.40
        User user-setting
        Port 2201
      Host user-host
        HostName 127.0.0.1
        User deploy
        Port 2222
      Host *
        ControlMaster auto
        ControlPath /tmp/user-ssh-%r@%h:%p
    '';
  in {
    checks.project-ssh-config = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [base operator];

      name = "project-ssh-config";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default];

      defaults = {pkgs, ...}: {
        services.openssh = {
          enable = true;
          startWhenNeeded = false;
          ports = [2222];
          authorizedKeysFiles = ["/var/lib/ssh-fixture/authorized_keys"];
          authorizedKeysInHomedir = false;
          settings = {
            AllowUsers = ["deploy" "operator"];
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
          };
        };
        users.users.deploy = {
          isNormalUser = true;
          hashedPassword = "*";
        };
        users.users.operator.hashedPassword = "*";
        programs.ssh.extraConfig = ''
          Host build-host
            HostName 192.0.2.30
            User system-setting
            Port 2200
          Host system-host
            HostName 127.0.0.1
            User deploy
            Port 2222
          Host *
            IdentityFile /home/operator/.ssh/id_ed25519
            IdentitiesOnly yes
            StrictHostKeyChecking accept-new
            BatchMode yes
            ConnectTimeout 10
        '';
        systemd.tmpfiles.rules = [
          "d /home/operator/.ssh 0700 operator operator -"
          "C /home/operator/.ssh/config 0600 operator operator - ${userConfig}"
          "d /var/lib/ssh-fixture 0755 root root -"
        ];
        systemd.services.ssh-fixture = {
          description = "Authorize the operator's test key for local SSH connections";
          requiredBy = ["sshd.service"];
          before = ["sshd.service"];
          after = ["systemd-tmpfiles-setup.service"];
          path = [pkgs.coreutils pkgs.openssh];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ssh-keygen -q -t ed25519 -N "" -f /home/operator/.ssh/id_ed25519
            chown operator:operator /home/operator/.ssh/id_ed25519*
            install -m 0644 /home/operator/.ssh/id_ed25519.pub /var/lib/ssh-fixture/authorized_keys
          '';
        };
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with project SSH settings";
          wantedBy = ["multi-user.target"];
          after = ["systemd-tmpfiles-setup.service"];
          path = [pkgs.coreutils pkgs.gnutar pkgs.gitMinimal];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "operator";
            Group = "operator";
            WorkingDirectory = "/home/operator";
          };
          script = ''
            tar -xf ${project}/project.tar
            git -C project init -q
            git -C project add -A
            mkdir project/nix/project-ssh
            cp ${sshModule} project/nix/project-ssh/flake-module.nix
          '';
        };
      };

      # Explicit SSH includes must be owned inside the container's user namespace.
      containerDefaults = {
        environment.etc."ssh/ssh_config".mode = "0644";
        programs.ssh.systemd-ssh-proxy.enable = false;
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
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        def ssh_config(arguments):
            output = operator("direnv exec . ssh -G " + arguments)
            return dict(line.split(" ", 1) for line in output.splitlines())

        start_all()
        machine.wait_for_unit("sshd.service")
        machine.wait_for_unit("idr-project-fixture.service")

        with subtest("load the project settings and connect using the development shell's SSH command"):
            operator("git add nix/project-ssh/flake-module.nix")
            operator("direnv allow")
            assert operator("direnv exec . ssh build-host whoami").strip() == "deploy"
            assert operator("direnv exec . ssh -l operator build-host whoami").strip() == "operator"
            assert operator("direnv exec . ssh user-host whoami").strip() == "deploy"
            assert operator("direnv exec . ssh system-host whoami").strip() == "deploy"

        with subtest("project SSH settings take precedence over user and system configuration"):
            settings = ssh_config("build-host")
            assert settings["hostname"] == "127.0.0.1", settings
            assert settings["user"] == "deploy", settings
            assert settings["port"] == "2222", settings
            assert settings["controlmaster"] == "false", settings
            # OpenSSH omits ControlPath from -G output when it is set to none.
            assert "controlpath" not in settings, settings

        with subtest("command-line options take precedence over the project's SSH configuration"):
            settings = ssh_config("-o HostName=192.0.2.50 -l operator -p 2223 build-host")
            assert settings["hostname"] == "192.0.2.50", settings
            assert settings["user"] == "operator", settings
            assert settings["port"] == "2223", settings
      '';
    });
  };
}

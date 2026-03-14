top: args @ {
  lib,
  config,
  self,
  inputs,
  ...
}: {
  imports = [
    top.inputs.devshell.flakeModule
    top.inputs.process-compose-flake.flakeModule
  ];

  perSystem = {
    config,
    system,
    pkgs,
    self',
    ...
  }: let
    scripts = ../../scripts;
    sshTemplatePath = ".data/ssh/${system}.template";
    sshTemplate = pkgs.writeText "idr-ssh-config.template" (
      ''
        Host *
          ControlMaster no
          ControlPath none
          UserKnownHostsFile "''${PRJ_DATA_DIR}/@AGENT_PREFIX@.known_hosts" ~/.ssh/known_hosts ~/.ssh/known_hosts2

      ''
      + config.devshells.default.idr.sshConfig
      + ''

        Host *
          Include ~/.ssh/config
          Include /etc/ssh/ssh_config
      ''
    );
    sshConfig =
      pkgs.writers.writeNuBin "idr-ssh-config" {
        makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.coreutils pkgs.gitMinimal])];
      } ''
        source ${scripts}/idr-ssh-config.nu
      '';
  in {
    idr.files.${sshTemplatePath} = {
      content = sshTemplate;
      postWrite = ''
        ${lib.getExe sshConfig} "$PRJ_ROOT/${sshTemplatePath}" > /dev/null
      '';
    };

    devshells.default = {
      imports = [top.self.modules.devshell.idr];
      devshell.prj_root_fallback.value = builtins.unsafeDiscardStringContext (toString self);
      env = [
        {
          name = "SSH_OPTS";
          eval = ''"$(${lib.getExe sshConfig} --ssh-opts ${sshTemplate})"'';
        }
        {
          name = "PC_SOCKET_PATH";
          eval = "$(${pkgs.nushell}/bin/nu -n --no-std-lib --no-history -c ${lib.escapeShellArg ''
            use ${scripts}/idr-common.nu [host-socket-prefix]
            mkdir $env.PRJ_DATA_DIR
            $env.PRJ_DATA_DIR | path join $"(host-socket-prefix 'pc').sock"
          ''})";
        }
      ];
      commands = [
        {
          name = "idr";
          package = config.process-compose.idr.outputs.package;
          help = "Manage services. (process-compose wrapper)";
        }
      ];
      packages = top.self.lib.inputsFrom [
        config.process-compose.idr.services.outputs.devShell
      ];
      idr = {
        inherit (args.config.idr) projectName;
        nixosRelease = inputs.nixpkgs.lib.trivial.release;
        additionalPaths = [self] ++ (top.self.lib.collectFlakeInputs inputs);
      };
    };

    process-compose.idr = {
      cli.preHook = ''
        # Let Process Compose resolve the command and its options before adding a startup-only flag.
        completion_args=()
        for arg; do
          [[ "$arg" == -- ]] && break
          completion_args+=("$arg")
        done
        case "$(process-compose __completeNoDesc "''${completion_args[@]}" --keep-proj 2>/dev/null)" in
          --keep-project*)
            set -- --keep-project "$@"
            ;;
        esac
      '';
      cli.options = {
        use-uds = lib.mkDefault true;
        no-server = false;
      };
      imports = [
        top.inputs.services-flake.processComposeModules.default
      ];
    };

    packages.default = self'.devShells.default;
  };
}

top: {
  lib,
  pkgs,
  config,
  inputs,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  cfg = config.idr;

  scripts = ../scripts;

  cleanupNu = pkgs.nushell.override {
    additionalFeatures = features: features ++ ["ctrlc/termination"];
  };

  ssh = pkgs.writers.writeNuBin "ssh" ''
    def --wrapped main [...args] {
      let options = if $env.IDR_SSH_CONFIG? != null {
        ["-F" $env.IDR_SSH_CONFIG]
      } else {
        let options = $env.SSH_OPTS? | default ""
        $"[($options)]" | from nuon
      }
      exec ${pkgs.openssh}/bin/ssh ...$options ...$args
    }
  '';

  idr-mk-project = pkgs.writeShellApplication {
    name = "idr-mk-project";

    runtimeInputs = with pkgs; [
      copier
      shellcheck-minimal
    ];

    text = ''
      if [[ "''${1:-}" == "-h" || "''${1:-}" == "--help" ]]; then
        echo "Usage: idr-mk-project DESTINATION [COPIER_OPTIONS...]"
        exit 0
      fi

      dest="$1"
      shift
      mkdir -p "$dest"
      cd "$dest"
      if ! [[ -f flake.lock ]]; then
        cp ${top.self}/flake.lock flake.lock
      fi
      export IDR_GIT_URL="ssh://git@github.com/idr-nix/idr?shallow=1"
      export IDR_GIT_REF="refs/heads/main"
      export IDR_GIT_REV="${top.self.rev or ""}"
      export IDR_GIT_DIRTY_REV="${top.self.dirtyRev or ""}"
      export IDR_GIT_DIRTY_SHORT_REV="${top.self.dirtyShortRev or ""}"
      export IDR_GIT_LAST_MODIFIED="${toString top.self.lastModified}"
      export IDR_GIT_NAR_HASH="${top.self.narHash}"
      export IDR_PATH="${top.self}"
      copier copy --trust ${top.self}/templates/project . "$@" -d idr_path=${top.self}
    '';
  };

  idr-setup-project = pkgs.writeShellApplication {
    name = "idr-setup-project";
    runtimeInputs = with pkgs; [nushell];
    text = ''
      exec nu -n --no-std-lib --no-history ${scripts}/idr-setup-project.nu "$@"
    '';
  };
  idr-mk-machine = pkgs.writeShellApplication {
    name = "idr-mk-machine";
    runtimeInputs = with pkgs; [nushell copier];
    text = ''
      export TEMPLATES_DIR=${lib.escapeShellArg cfg.templatesDir}
      export IDR_NIXOS_RELEASE=${lib.escapeShellArg cfg.nixosRelease}
      exec nu -n --no-std-lib --no-history ${scripts}/idr-mk-machine.nu "$@"
    '';
  };
  idr-with-project-lock = pkgs.writeShellApplication {
    name = "idr-with-project-lock";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      exec ${lib.getExe cleanupNu} -n --no-std-lib --no-history ${scripts}/idr-with-project-lock.nu "$@"
    '';
  };
in {
  options.idr = {
    projectName = lib.mkOption {
      description = ''
        Project name
      '';
      type = lib.types.str;
    };
    sshConfig = lib.mkOption {
      description = ''
        SSH configuration added before the user's and system's configuration.
      '';
      type = lib.types.lines;
      default = "";
    };
    nixosRelease = lib.mkOption {
      description = ''
        NixOS release used as the initial stateVersion for generated machines.
      '';
      type = lib.types.str;
      internal = true;
      default = pkgs.lib.trivial.release;
    };
    templatesDir = lib.mkOption {
      description = ''
        Path to the templates directory used for generating project, machine, role, and module configurations.
      '';
      type = lib.types.path;
      internal = true;
      defaultText = "<idr-repo/templates>";
      default = "${builtins.unsafeDiscardStringContext (toString top.self)}/templates";
    };
    additionalPaths = lib.mkOption {
      description = ''
        Additional store paths to include in the devshell closure, ensuring offline availability.
      '';
      type = lib.types.listOf lib.types.path;
      default = [];
    };
  };

  imports = [
    {
      env = lib.mkBefore [
        {
          name = "PRJ_DATA_DIR";
          eval = "\${PRJ_DATA_DIR:-$([ -w \"$PRJ_ROOT\" ] && echo \"$PRJ_ROOT/.data\" || echo \"$PWD/.data\")}";
        }
        {
          name = "PATH";
          prefix = "${pkgs.bashInteractive}/bin";
        }
      ];
    }
  ];

  config = {
    _module.args = {
      idrSsh = ssh;
      idrNu = cleanupNu;
    };
    commands = [
      {
        name = "idr-mk-project";
        package = idr-mk-project;
        help = "Initialize a project";
      }
      {
        name = "idr-mk-machine";
        package = idr-mk-machine;
        help = "Create a machine configuration";
      }
      {
        name = "ssh";
        package = lib.hiPrio ssh;
        help = "Connect over SSH using project configuration";
      }
    ];

    packages =
      [
        (pkgs.linkFarm "additional-paths" {
          ".additional-paths" = pkgs.writeClosure cfg.additionalPaths;
        })
      ]
      ++ (with pkgs; [
        alejandra
        nushell
        idr-setup-project
        idr-with-project-lock
        fd
        flock
      ]);

    devshell.startup_env = lib.mkForce ''
      if [[ -f "$PRJ_ROOT/.env" ]]; then
        set -a
        source "$PRJ_ROOT/.env"
        set +a
      fi
      export IDR_PROJECT_NAME=${lib.escapeShellArg config.idr.projectName}
      ${lib.concatStringsSep "\n" config.env}
    '';

    # Keep shell build tools available for offline rebuilds.
    idr.additionalPaths =
      [
        top.inputs.devshell.packages.${system}.default.stdenv.stdenv # support offline rebuild for devshell
      ]
      ++ (with pkgs; [
        stdenv # support offline rebuild for devshell
        jq.dev # support offline rebuild for pkgs.writeClosure
        nixos-render-docs # support offline documentation for newly added modules
        (nixosOptionsDoc {options = {};}).optionsJSON.inputDerivation # support offline option documentation rebuilds
      ]);
  };
}

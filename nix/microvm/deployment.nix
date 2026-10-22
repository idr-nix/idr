{
  lib,
  pkgs,
  inputs,
  unitName,
  instanceName,
  hostName,
  vmName,
  vm,
  machine,
  sshHostKeyPath,
  vsockSocket,
}: let
  guest = machine.config;
  meta = guest.system.build.idr.meta;
  stateDirectory = "/var/lib/${unitName}-deploy";
  deployRs = inputs.deploy-rs.packages.${machine.pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
    # A guest may have been updated directly with nixos-rebuild between host
    # deployments. Its previous profile then has no deploy-rs activation wrapper.
    patches = (old.patches or []) ++ [./deploy-rs-nixos-rollback.patch];
  });
  activation = import ../idr/deploy/microvm-activation.nix {
    inherit lib machine;
    pkgs = machine.pkgs;
    activation = inputs.deploy-rs.lib.${machine.pkgs.stdenv.hostPlatform.system}.activate.nixos machine;
    activateProgram = lib.getExe' deployRs "activate";
  };
  activateGuest = machine.pkgs.writeShellScript "${unitName}-activate" ''
    set -euo pipefail
    trap "" HUP
    if ! ${machine.pkgs.diffutils}/bin/cmp -s /run/current-system/etc/idr-microvm-identity ${guest.environment.etc."idr-microvm-identity".source}; then
      printf '%s\n' ${lib.escapeShellArg "Refusing to deploy ${guest.networking.hostName}: the target is not this MicroVM."} >&2
      exit 1
    fi
    # --rollback chooses the preceding numbered generation. After a manual
    # rollback or a boot-only update that need not be the running system.
    # Record the running system as the latest predecessor before deploying.
    ${machine.pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system \
      --set "$(${machine.pkgs.coreutils}/bin/readlink -f /run/current-system)"
    exec ${activation}/activate-rs activate ${activation} \
      --profile-path /nix/var/nix/profiles/system --auto-rollback --magic-rollback \
      --confirm-timeout 30 --temp-path "$1"
  '';
  desiredPin = pkgs.writeText "${unitName}-guest-host-key" (meta.sshHostPublicKey + "\n");
  receiver = machine.pkgs.writers.writeNuBin "idr-copy-extra-files-receiver" {
    makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [machine.pkgs.coreutils])];
  } (builtins.readFile ../scripts/idr-copy-extra-files-receiver.nu);
  files = pkgs.writeText "${unitName}-deployment-files.json" (builtins.toJSON {
    postFormatFiles = lib.mapAttrs (_: file:
      file
      // {
        publicKey =
          if file.key == "ssh_host_ed25519_key"
          then meta.sshHostPublicKey
          else if file.key == "initrd_ssh_host_ed25519_key"
          then meta.initrdHostPublicKey
          else null;
      })
    meta.disko.postFormatFiles;
    receiver = lib.getExe receiver;
  });
  stageFiles =
    pkgs.writers.writeNuBin "${unitName}-copy-extra-files" {
      makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.coreutils pkgs.openssh pkgs.sops])];
    } (''
        use ${../scripts/idr-common.nu} [with-disko-files]
      ''
      + builtins.readFile ./deployment.nu);
  workerConfig = pkgs.writeText "${unitName}-connection.json" (builtins.toJSON {
    state_dir = stateDirectory;
    target = unitName;
    identity_path = sshHostKeyPath;
    desired_pin = desiredPin;
    guest_identity = guest.idr.preset.base.id;
    guest_toplevel = toString guest.system.build.toplevel;
    activation = toString activation;
    activate_guest = toString activateGuest;
    receiver = toString receiver;
    proxy = "${pkgs.systemd}/lib/systemd/systemd-ssh-proxy vsock-mux/${vsockSocket} %p";
    stage_files = lib.getExe stageFiles;
    files = toString files;
    ssh_to_age = "${pkgs.ssh-to-age}/bin/ssh-to-age";
  });
  # Even with ctrlc/termination, Nu interrupts waits inside finally on cancellation.
  # Keep the rollback grace period and credential lock in this supervisor.
  worker = pkgs.writeShellApplication {
    name = "${unitName}-connection";
    runtimeInputs = with pkgs; [coreutils diffutils openssh nix nushell util-linux];
    text = ''
      if (( EUID != 0 )); then
        echo "MicroVM management requires root." >&2
        exit 1
      fi
      action=''${1:-}
      if [[ $action != deploy && $action != ssh ]] || [[ $action == deploy && $# != 1 ]]; then
        echo "Expected deploy without arguments, or ssh [SSH_ARGUMENTS...]." >&2
        exit 1
      fi
      umask 077
      state_dir=${lib.escapeShellArg stateDirectory}
      install -d -m 0700 -o root -g root "$state_dir"
      exec 9>"$state_dir/deployment.lock"
      if [[ $action == ssh ]]; then flock --shared 9; else flock --exclusive 9; fi
      work=$(mktemp -d "$state_dir/.session-XXXXXXXX")
      cleanup() {
        # Preserve the lock and transport while an interrupted switch rolls back.
        local deadline=$((SECONDS + 45))
        while [[ -f $work/activation-started && ! -f $work/activation-finished ]] && (( SECONDS < deadline )); do
          sleep 1
        done
        ssh -F "$work/ssh.conf" -O exit ${lib.escapeShellArg unitName} >/dev/null 2>&1 || true
        rm -rf -- "$work"
      }
      worker_pid=
      interrupt() {
        trap "" INT TERM
        if [[ -n $worker_pid ]]; then
          kill -TERM "$worker_pid" 2>/dev/null || true
          wait "$worker_pid" 2>/dev/null || true
        fi
        exit "$1"
      }
      trap cleanup EXIT
      trap 'interrupt 130' INT
      trap 'interrupt 143' TERM
      # Waiting on a background child lets the traps cancel Nu immediately.
      nu --no-config-file --no-std-lib --no-history ${./deployment-worker.nu} ${workerConfig} "$work" "$action" &
      worker_pid=$!
      wait "$worker_pid"
      worker_pid=
      if [[ $action == ssh ]]; then
        shift
        ssh -F "$work/ssh.conf" ${lib.escapeShellArg unitName} "$@"
      fi
    '';
  };
  deploy = pkgs.writeShellApplication {
    name = "${unitName}-deploy";
    runtimeInputs = [pkgs.coreutils pkgs.nix];
    text = ''
      flake=.
      while (( $# )); do
        case "$1" in
          --flake)
            if (( $# < 2 )); then
              echo "--flake requires a flake reference." >&2
              exit 1
            fi
            flake=$2
            shift 2
            ;;
          --flake=*) flake=''${1#*=}; shift ;;
          --help|-h)
            cat <<'EOF'
      Usage: ${unitName}-deploy [--flake FLAKE] [-- NIX_BUILD_ARGUMENTS...]

      Build and deploy this guest from the current checkout on its VM host.
      --flake selects another checkout or flake reference (default: .).
      Run as your normal user; sudo is used only to deploy the built system.
      EOF
            exit 0
            ;;
          --) shift; break ;;
          *) echo "Unknown argument: $1. Use --help for usage." >&2; exit 1 ;;
        esac
      done
      if [[ -z $flake || $flake == *'#'* ]]; then
        echo "--flake must be a nonempty flake reference without an attribute fragment." >&2
        exit 1
      fi
      attribute=${lib.escapeShellArg "nixosConfigurations.${builtins.toJSON hostName}.config.system.build.idrMicrovmDeployments.${builtins.toJSON vmName}"}
      output=$(nix --extra-experimental-features 'nix-command flakes' build \
        --no-link --print-out-paths --no-write-lock-file "$flake#$attribute" "$@")
      program="$output/bin/${unitName}-connection"
      if [[ -z $output || $output == *$'\n'* || ! -x $program ]]; then
        echo "The repository did not build a single MicroVM deployment helper." >&2
        exit 1
      fi
      if (( EUID == 0 )); then
        exec "$program" deploy
      fi
      exec sudo -- "$program" deploy
    '';
  };
  ssh = pkgs.writeShellScriptBin "${unitName}-ssh" ''
    exec ${lib.getExe worker} ssh "$@"
  '';
in {
  inherit activation stateDirectory worker;
  package = pkgs.symlinkJoin {
    name = "${unitName}-deployment";
    paths = [deploy ssh];
  };
  service = {
    enable = vm.deployment.autoUpdate;
    description = "Deploy the installed system of MicroVM ${guest.networking.hostName}";
    requiredBy = lib.optional vm.deployment.autoUpdate "sysinit-reactivation.target";
    before = ["sysinit-reactivation.target"];
    after = ["microvm@${instanceName}.service" "sshd-keygen.service"];
    partOf = ["sysinit-reactivation.target"];
    restartIfChanged = false;
    unitConfig = {
      ConditionCredential = "!idr.workspace-id";
    };
    script = ''
      if ! ${pkgs.systemd}/bin/systemctl is-active --quiet microvm@${instanceName}.service; then
        echo "Skipping guest update: MicroVM is not running."
        exit 0
      fi
      exec ${lib.getExe worker} deploy
    '';
    serviceConfig = {
      Type = "oneshot";
      # A skipped guest stays skipped when NixOS starts active targets again
      # later in the switch. Only the next reactivation restarts this service.
      RemainAfterExit = true;
      User = "root";
      StateDirectory = "${unitName}-deploy";
      StateDirectoryMode = "0700";
      UMask = "0077";
      TimeoutStartSec = 600;
    };
  };
}

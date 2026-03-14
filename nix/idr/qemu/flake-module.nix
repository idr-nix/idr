top: {
  lib,
  self,
  ...
}: {
  flake.modules.devshell.idr = lib.modules.importApply ./devshell.nix top;

  perSystem = {
    system,
    pkgs,
    ...
  }: let
    scripts = ../../scripts;
    machineConfigurations =
      lib.filterAttrs (
        _name: machine:
          machine.pkgs.stdenv.hostPlatform.system
          == system
          && machine.config.system.build ? idrQemu
      )
      (self.nixosConfigurations or {});

    sshReadiness =
      pkgs.writers.writeNuBin "idr-qemu-ready" {
        makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.gitMinimal pkgs.openssh])];
      } ''
        source ${scripts}/idr-qemu-ready.nu
      '';

    machineProcesses =
      lib.concatMapAttrs (machineName: machine: let
        cfg = machine.config;
        publicKey = cfg.system.build.idr.meta.sshHostPublicKey;
        sopsFile = cfg.system.build.idr.meta.defaultSopsFile or null;
      in {
        "vm-${machineName}" = {
          availability.restart = "no";
          command = cfg.system.build.idrQemu;
          disabled = true;
          namespace = "vm-${machineName}";
          readiness_probe = lib.mkIf (cfg.services.openssh.enable && publicKey != null) (lib.mkDefault {
            exec.command = lib.escapeShellArgs ([
                (lib.getExe sshReadiness)
                cfg.idr.qemu.networkPrefix
                cfg.idr.preset.base.id
                (toString (builtins.head cfg.services.openssh.ports))
                publicKey
              ]
              ++ lib.optionals (sopsFile != null) [
                "--sops-file"
                (lib.removePrefix "${self}/" (toString sopsFile))
              ]);
            period_seconds = 10;
            timeout_seconds = 5;
            # Allow 30 days for image builds and booting, including the first immediate probe.
            failure_threshold = builtins.div (30 * 24 * 60 * 60) 10 + 1;
          });
        };
      })
      machineConfigurations;

    sshKey =
      pkgs.writers.writeNuBin "idr-ssh-key" {
        makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.coreutils pkgs.flock pkgs.openssh pkgs.sops])];
      } ''
        source ${scripts}/idr-ssh-key.nu
      '';
  in {
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux ({
        nixos-guest-access = import ./checks/guest-access.nix {
          inherit pkgs;
          inherit (top) inputs self;
        };
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
        nixos-qemu-lifecycle = import ./checks/lifecycle.nix {
          inherit pkgs;
          inherit (top) inputs self;
        };
      });

    devshells.default.idr.sshConfig = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: machine: let
        cfg = machine.config;
        machineId = lib.concatStringsSep ":" (lib.genList (i: builtins.substring (i * 4) 4 cfg.idr.preset.base.id) 3);
      in ''
        Host vm-${name}
          HostName ${cfg.idr.qemu.networkPrefix}:@WORKSPACE_ID@:${machineId}
          User root
          Port ${toString (builtins.head cfg.services.openssh.ports)}
          IdentityAgent "''${PRJ_DATA_DIR}/@AGENT_PREFIX@-${cfg.idr.preset.base.id}.sock"
          IdentitiesOnly no
        Match originalhost vm-${name} !final exec "${lib.getExe sshKey} add ${lib.escapeShellArgs [name cfg.idr.preset.base.id]}"
      '')
      machineConfigurations);

    process-compose.idr.settings.processes = machineProcesses;
  };
}

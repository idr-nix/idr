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
        _name: machine: machine.config.system.build ? idrQemu
      )
      (self.nixosConfigurations or {});
    imageConfigurations = lib.filterAttrs (
      _name: machine: machine.config.system.build ? diskoImagesScript
    ) (self.nixosConfigurations or {});

    hostLinuxSystem = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux";
    hostLinuxPkgs = let
      base = top.inputs.nixpkgs.legacyPackages.${hostLinuxSystem};
    in
      base
      // lib.optionalAttrs base.stdenv.hostPlatform.isAarch64 {
        pkgsStatic = base.pkgsStatic.extend (_final: previous: {
          qemu-user = previous.qemu-user.overrideAttrs (old: let
            keepInput = input: (input.pname or "") != "gnutls";
          in {
            env =
              (old.env or {})
              // {
                NIX_CFLAGS_LINK = lib.concatStringsSep " " (
                  lib.filter (flag: flag != "-static") (
                    lib.splitString " " (old.NIX_CFLAGS_LINK or ((old.env or {}).NIX_CFLAGS_LINK or ""))
                  )
                );
              };
            configureFlags =
              map (
                flag:
                  if flag == "--enable-gnutls"
                  then "--disable-gnutls"
                  else flag
              )
              old.configureFlags;
            buildInputs = lib.filter keepInput (old.buildInputs or []);
            propagatedBuildInputs = lib.filter keepInput (old.propagatedBuildInputs or []);
          });
        });
      };
    imageBuilderQemu = let
      qemu =
        (import (hostLinuxPkgs.path + "/nixos/lib/qemu-common.nix") {
          inherit lib;
          stdenv = hostLinuxPkgs.stdenv;
        }).qemuBinary
        hostLinuxPkgs.qemu;
    in
      if hostLinuxPkgs.stdenv.hostPlatform.isAarch64
      then
        toString (hostLinuxPkgs.writeShellScript "idr-image-build-qemu" ''
          if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
            # Match the local runner's TCG CPU: EDK2 202602 cannot boot with LPA2.
            exec ${hostLinuxPkgs.qemu}/bin/qemu-system-aarch64 \
              -machine virt,gic-version=max,accel=tcg -cpu max,lpa2=off "$@"
          fi
          exec ${qemu} "$@"
        '')
      else qemu;
    diskoImagesScript = machine: let
      foreignSystem = machine.pkgs.stdenv.hostPlatform.system != hostLinuxSystem;
      builderPkgs =
        if foreignSystem
        then hostLinuxPkgs
        else machine.config.disko.imageBuilder.pkgs;
      storeVirtiofsd = builderPkgs.writers.writeNuBin "virtiofsd" {} ''
        def --wrapped main [...args: string] {
          # All source store paths exist before the builder starts and are immutable.
          # The writable exchange share keeps its normal cache policy.
          let store_share = ($"--shared-dir=${builtins.storeDir}" in $args) or (
            $args | window 2 | any {|pair| $pair == ["--shared-dir" "${builtins.storeDir}"]}
          )
          let explicit_cache = $args | any {|arg| $arg == "--cache" or ($arg | str starts-with "--cache=")}
          let cache = if $store_share and not $explicit_cache { ["--cache" "always"] } else { [] }
          exec ${lib.getExe builderPkgs.virtiofsd} ...$args ...$cache
        }
      '';
      parallelBuilderPkgs =
        (import ./parallel-image-allocation.nix {
          inherit lib;
          pkgs = builderPkgs;
          diskDevices = machine.config.disko.devices.disk;
          imageFormat = machine.config.disko.imageBuilder.imageFormat;
        })
        // {
          vmTools = builderPkgs.vmTools.override {virtiofsd = storeVirtiofsd;};
        };
      installedMachine = machine.extendModules {
        modules = [
          machine.config.disko.imageBuilder.extraConfig
          {
            system.activationScripts = lib.optionalAttrs foreignSystem {
              idr-install-tmp = "mkdir -p -m 1777 /tmp";
            };
          }
        ];
      };
      installedProfile = top.inputs.deploy-rs.lib.${machine.pkgs.stdenv.hostPlatform.system}.activate.nixos installedMachine;
    in
      (machine.extendModules {
        modules = [
          {
            disko.imageBuilder =
              {
                extraConfig = lib.mkForce {
                  imports = [
                    machine.config.disko.imageBuilder.extraConfig
                    (lib.modules.importApply ./parallel-disk-setup.nix {pkgs = builderPkgs;})
                    ({config, ...}: {
                      # Include the installed profile in Disko's copied/registered
                      # closure while retaining its temporary partitioning system.
                      system.extraDependencies = [installedProfile];
                      system.build = {
                        # Disko's virtio substitutions are only for partitioning. Persist
                        # the runtime devices and deploy-rs entrypoints for rollback.
                        idr = lib.mkForce machine.config.system.build.idr;
                        nixos-install = lib.mkForce (hostLinuxPkgs.writeShellScriptBin "nixos-install" ''
                          set -euo pipefail
                          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: disk: let
                            buildDevice = config.disko.devices.disk.${name}.device;
                          in
                            lib.optionalString (disk.device != buildDevice) ''
                              # These aliases live only in the builder's /dev, which
                              # nixos-install also exposes inside its target chroot.
                              if [ -e ${lib.escapeShellArg disk.device} ]; then
                                test "$(readlink -f ${lib.escapeShellArg disk.device})" = ${lib.escapeShellArg buildDevice}
                              else
                                mkdir -p ${lib.escapeShellArg (builtins.dirOf disk.device)}
                                ln -s ${lib.escapeShellArgs [buildDevice disk.device]}
                              fi
                            '')
                          machine.config.disko.devices.disk)}
                          exec ${machine.config.system.build.nixos-install}/bin/nixos-install "$@" --system ${installedProfile}
                        '');
                      };
                    })
                  ];
                };
                pkgs = parallelBuilderPkgs;
              }
              // lib.optionalAttrs (foreignSystem || hostLinuxPkgs.stdenv.hostPlatform.isAarch64) {
                qemu =
                  if foreignSystem
                  then imageBuilderQemu
                  else lib.mkDefault imageBuilderQemu;
              }
              // lib.optionalAttrs foreignSystem {
                kernelPackages = hostLinuxPkgs.linuxPackages;
                enableBinfmt = true;
              };
          }
        ];
      }).config.system.build.diskoImagesScript;

    imageBuilders = lib.mapAttrs (_name: diskoImagesScript) imageConfigurations;

    hostRuntime = top.inputs.idr.packages.${system}.idr-qemu-runtime;
    qemuProcess = machine: let
      inherit (machine.config.system.build) idrQemu;
    in
      if machine.pkgs.stdenv.hostPlatform.system == system
      then removeAttrs (idrQemu.processCompose or {command = idrQemu;}) ["commandFor"]
      else {
        inherit (idrQemu.processCompose) environment;
        command = idrQemu.processCompose.commandFor hostRuntime;
      };

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
        "vm-${machineName}" =
          (
            if pkgs.stdenv.hostPlatform.isLinux && machine.pkgs.stdenv.hostPlatform.system == hostLinuxSystem
            then qemuProcess machine
            else {
              command = ''
                exec ${lib.getExe pkgs.nix} ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux "--offline "}-L run ${lib.escapeShellArg "${self}#vm-${machineName}"} -- "$@"
              '';
            }
          )
          // {
            availability.restart = "no";
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
    devshells.default.idr.additionalPaths =
      lib.optionals pkgs.stdenv.hostPlatform.isDarwin [hostRuntime]
      ++ lib.optionals (
        pkgs.stdenv.hostPlatform.isLinux
        && lib.any (machine: machine.pkgs.stdenv.hostPlatform.system != hostLinuxSystem) (builtins.attrValues imageConfigurations)
      ) [hostLinuxPkgs.pkgsStatic.qemu-user];

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

    legacyPackages = {
      idrDiskoImagesScript = imageBuilders;
      idrDiskoImagesInfo =
        lib.mapAttrs (name: machine: {
          metadata = machine.config.system.build.idr.meta.disko;
          builder = imageBuilders.${name}.drvPath;
        })
        imageConfigurations;
    };

    packages = lib.mapAttrs' (name: machine: let
      process = qemuProcess machine;
    in
      lib.nameValuePair "vm-${name}" (pkgs.writeShellApplication {
        name = "vm-${name}";
        text = lib.concatMapStrings (variable: "export ${lib.escapeShellArg variable}\n") (process.environment or []) + process.command;
      }))
    machineConfigurations;
  };
}

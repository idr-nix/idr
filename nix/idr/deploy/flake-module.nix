top: {
  lib,
  config,
  getSystem,
  ...
}: let
  sshConfigFor = system:
    import ./ssh-config.nix {
      inherit lib;
      deploy = config.flake.deploy;
      projectConfig = (getSystem system).devshells.default.idr.sshConfig;
    };
in {
  options.flake.deploy = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    description = ''
      deploy-rs configuration. Each NixOS configuration has a system profile
      that deploys to its networking.hostName by default.
    '';
  };

  config.flake.modules.devshell.idr = lib.modules.importApply ./devshell.nix top;

  config.flake.deploy = {
    sshUser = lib.mkDefault "root";
    nodes = lib.concatMapAttrs (name: machine: let
      inherit (machine) pkgs;
      inherit (pkgs.stdenv.hostPlatform) system;
      inherit (machine.config.system) build;
      sshConfig = sshConfigFor system;
      isMicroVM = machine.config.idr.microvmGuest.enable or false;
      guestAddress = machine.config.idr.microvmGuest.network.ipv4Address or null;
      baseActivation = top.inputs.deploy-rs.lib.${system}.activate.nixos machine;
      activation =
        if isMicroVM
        then
          import ./microvm-activation.nix {
            inherit lib pkgs machine;
            activation = baseActivation;
          }
        else baseActivation;
      profiles = qemuProcess: {
        system = {
          user = lib.mkDefault "root";
          path = lib.mkDefault (activation.overrideAttrs (old: {
            passthru =
              (old.passthru or {})
              // {
                idr =
                  build.idr
                  // {
                    inherit qemuProcess;
                    globalSshOpts = config.flake.deploy.sshOpts or [];
                  };
              };
          }));
        };
      };
    in
      {
        ${name} = {
          hostname = lib.mkDefault (
            if isMicroVM && guestAddress != null
            then guestAddress
            else machine.config.networking.hostName
          );
          sshOpts = lib.mkDefault (lib.optionals (!sshConfig.hasPackagePaths) ["-F" sshConfig.common]);
          profiles = profiles null;
        };
      }
      // lib.optionalAttrs (machine.config.system.build ? idrQemu) {
        "vm-${name}" = {
          hostname = lib.mkDefault "vm-${name}";
          fastConnection = lib.mkDefault true;
          activationTimeout = lib.mkDefault 600;
          profiles = profiles "vm-${name}";
        };
      })
    config.flake.nixosConfigurations;
  };
}

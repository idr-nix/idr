top: {
  lib,
  config,
  ...
}: {
  options.flake.deploy = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    description = ''
      deploy-rs configuration. Each NixOS configuration has a system profile
      that deploys to its networking.hostName by default.
    '';
  };

  config.flake.modules.devshell.idr = lib.modules.importApply ./devshell.nix top;

  config.perSystem = {pkgs, ...}: {
    checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
      nixos-installation = import ./checks/installation.nix {
        inherit pkgs;
        inherit (top) inputs self;
      };
    };
  };

  config.flake.deploy = {
    sshUser = lib.mkDefault "root";
    nodes = lib.concatMapAttrs (name: machine: let
      inherit (machine) pkgs;
      inherit (pkgs.stdenv.hostPlatform) system;
      inherit (machine.config.system) build;
      activation = top.inputs.deploy-rs.lib.${system}.activate.nixos machine;
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
          hostname = lib.mkDefault machine.config.networking.hostName;
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

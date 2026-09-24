top: moduleArgs @ {
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
  hostSSHKeyPaths = config.sops.age.sshKeyPaths;
  containers = lib.filterAttrs (name: container: container.privateUsers == "no" && !container.privateNetwork) config.containers;
in {
  options.idr.preset.base = {
    reloadContainersWhenPossible = lib.mkOption {
      description = ''
        See https://github.com/NixOS/nixpkgs/pull/307951
      '';
      type = lib.types.bool;
      default = true;
    };
  };
  options.containers = lib.mkOption {
    # "description" field intentionally skipped, otherwise it will conflict with upstream NixOS containers module.
    type = lib.types.attrsOf (lib.types.submodule ({
      config,
      name,
      lib,
      ...
    }: {
      config = lib.optionalAttrs cfg.base.enable {
        autoStart = lib.mkDefault true;
        bindMounts = lib.listToAttrs (map (path:
          lib.nameValuePair "${path}${lib.optionalString (moduleArgs.config.containers.${name}.privateUsers != "no") ":idmap"}" {
            isReadOnly = true;
            hostPath = path;
          })
        hostSSHKeyPaths);
        privateUsers = lib.mkDefault "no";
        specialArgs = {inherit (top) inputs;};
        extraFlags = ["--link-journal=host"];
        config = {
          config,
          lib,
          pkgs,
          ...
        }: {
          imports = builtins.attrValues top.inputs.idr.modules.nixos;

          users.groups =
            lib.optionalAttrs (moduleArgs.options ? sops)
            (lib.concatMapAttrs (name: secret: {
                ${secret.group} = {};
              })
              (lib.filterAttrs (name: secret: secret.group != null) moduleArgs.config.sops.secrets));

          sops.age.sshKeyPaths = lib.mkDefault hostSSHKeyPaths;

          sops.secrets = lib.optionalAttrs (moduleArgs.options ? sops) (lib.mapAttrs (name: secret: let
              unitExists = unit: let
                templateParts = builtins.match "([^@]+)@.+(\\.[^.]+)" unit;
              in
                lib.hasAttr unit config.systemd.units
                || (templateParts
                  != null
                  && lib.hasAttr (lib.concatStringsSep "@" templateParts) config.systemd.units);
            in {
              inherit
                (secret)
                name
                key
                sopsFile
                group
                mode
                format
                owner
                uid
                gid
                neededForUsers
                ;
              restartUnits = builtins.filter unitExists secret.restartUnits;
              reloadUnits = builtins.filter unitExists secret.reloadUnits;
            })
            moduleArgs.config.sops.secrets);

          idr.secrets-source = moduleArgs.config.idr.secrets-source;

          idr.preset.base.enable = lib.mkDefault true;

          system.stateVersion = lib.mkDefault moduleArgs.config.system.stateVersion;

          systemd.services.logrotate.serviceConfig.PrivateNetwork = lib.mkOverride 51 false;
        };
      };
    }));
  };

  config = lib.mkIf cfg.base.enable (lib.mkMerge [
    {
      # Keep containers running during activation and restart them afterwards.
      systemd.services = lib.mapAttrs' (name: _:
        lib.nameValuePair "container@${name}" {stopIfChanged = false;})
      config.containers;
    }

    (lib.mkIf cfg.base.reloadContainersWhenPossible {
      systemd.services =
        lib.concatMapAttrs (name: _: let
          containerFile = config.environment.etc."nixos-containers/${name}.conf";
          runtimeConfig = lib.concatStringsSep "\n" (builtins.filter
            (line: !(lib.hasPrefix "SYSTEM_PATH=" line || lib.hasPrefix "FLAKE=" line))
            (lib.splitString "\n" containerFile.text));
        in {
          "container@${name}" = {
            serviceConfig.TimeoutStartSec = lib.mkForce "5min";
            after = ["systemd-networkd.service" "nftables.service"];
            # Hashing also discards the system path's Nix string context.
            restartTriggers = lib.mkForce [(builtins.hashString "sha256" runtimeConfig)];
            reloadTriggers = [containerFile.source];
          };
        })
        containers;
    })
  ]);
}

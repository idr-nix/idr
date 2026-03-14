top: args @ {
  lib,
  config,
  self,
  inputs,
  flake-parts-lib,
  ...
}: let
  inherit (lib) mkOption types;
  scripts = ../../scripts;
in {
  options.idr = {
    roleDirs = lib.mkOption {
      description = ''
        List of directories relative to the project root.
        Used to generate .sops.yaml for roles from the specified directories.
      '';
      type = lib.types.listOf lib.types.str;
      default = [];
      defaultText = lib.literalExpression ''["nix/role"]'';
    };
    machineDirs = lib.mkOption {
      description = ''
        List of directories relative to the project root.
        Used to generate .sops.yaml for machines from the specified directories.
      '';
      type = lib.types.listOf lib.types.str;
      default = [];
      defaultText = lib.literalExpression ''["nix/machine"]'';
    };
    sops = {
      stores = {
        json = {
          indent = lib.mkOption {
            description = ''
              Number of spaces for indentation in JSON output.
            '';
            type = lib.types.int;
            default = 2;
          };
        };
        json_binary = {
          indent = lib.mkOption {
            description = ''
              Number of spaces for indentation in JSON binary output.
            '';
            type = lib.types.int;
            default = 2;
          };
        };
        yaml = {
          indent = lib.mkOption {
            description = ''
              Number of spaces for indentation in YAML output.
            '';
            type = lib.types.int;
            default = 2;
          };
        };
      };
      creation_rules = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              priority = lib.mkOption {
                type = lib.types.int;
                default = 0;
                description = "Priority for ordering rules. Higher comes first.";
              };
              rule = lib.mkOption {
                type = lib.types.attrsOf lib.types.unspecified;
                description = "A single SOPS creation rule, using raw attributes.";
              };
            };
          }
        );

        default = [];
        description = "List of SOPS creation rules with priority and raw rule attributes.";
      };
    };
  };

  options.perSystem = flake-parts-lib.mkPerSystemOption ({
    config,
    system,
    pkgs,
    ...
  }: {
    packages = lib.optionalAttrs (args.config.idr.sops.creation_rules != []) {
      idr-sops-config = config.idr.files.".sops.yaml".content;
    };

    devshells.default = {
      devshell.startup.idr-sops-write-rotation-metadata = {
        deps = ["idr-write-files"];
        text = ''
          idr-with-project-lock ${pkgs.writeShellScript "idr-write-rotation-metadata" ''
            set -e
            nu -n --no-std-lib --no-history ${scripts}/idr-write-last-changed-files-metadata.nu
            nu -n --no-std-lib --no-history ${scripts}/idr-sops-write-rotation-metadata.nu
          ''}
        '';
      };
      devshell.startup.idr-sops-clean-host-keys = {
        deps = ["idr-write-files"];
        text = ''
          nu -n --no-std-lib --no-history ${scripts}/idr-sops-clean-host-keys.nu
        '';
      };
    };

    idr.files.".sops.yaml" = lib.mkIf (builtins.length args.config.idr.sops.creation_rules > 0) {
      copy = true;
      content = pkgs.writers.writeYAML ".sops.yaml" (args.config.idr.sops
        // {
          creation_rules =
            builtins.map
            (item: item.rule)
            (lib.sort (a: b: a.priority > b.priority) args.config.idr.sops.creation_rules);
        });
      postWrite = ''
        nu -n --no-std-lib --no-history ${scripts}/idr-sops-updatekeys.nu
      '';
    };
  });

  config = {
    flake.modules.devshell.idr = lib.modules.importApply ./devshell.nix top;

    idr.roleDirs = ["nix/role"];
    idr.machineDirs = ["nix/machine"];
    idr.sops.creation_rules = let
      subDirectories = dirs:
        lib.concatMap
        (dir:
          lib.optionals
          (builtins.pathExists "${self}/${dir}")
          (lib.mapAttrsToList
            (name: _: "${dir}/${name}")
            (lib.filterAttrs (_: type: type == "directory") (builtins.readDir "${self}/${dir}"))))
        dirs;
      machines =
        lib.flatten
        (builtins.map
          (
            machineDir: let
              hostName = builtins.baseNameOf machineDir;
              prefix = lib.escape ["/" "-"] (lib.escapeRegex machineDir);
              hasConfig =
                self.nixosConfigurations ? ${hostName}.config.idr.preset.base.enable
                && self.nixosConfigurations.${hostName}.config.idr.preset.base.enable;
              cfg = lib.optionalAttrs hasConfig self.nixosConfigurations.${hostName}.config;
              id = cfg.idr.preset.base.id;
              sops =
                lib.optionalAttrs
                (cfg.idr.preset.base.defaultSopsFile != null && lib.hasSuffix ".json" cfg.idr.preset.base.defaultSopsFile)
                (builtins.fromJSON (builtins.readFile cfg.idr.preset.base.defaultSopsFile));
              recipients = lib.flatten (lib.mapAttrsToList
                (
                  member_name: member:
                    lib.optional
                    (member ? groups && builtins.elem "host-${hostName}-${id}" member.groups && member ? agePublicKey)
                    member.agePublicKey
                )
                top.self.lib.team);
            in
              lib.optional hasConfig {
                recipients =
                  recipients
                  ++ (
                    lib.optional
                    (sops ? ssh_host_ed25519_key_age_pub_unencrypted)
                    sops.ssh_host_ed25519_key_age_pub_unencrypted
                  );
                path_regex = "^${prefix}\\/.*\\.enc\\.(json|yaml|bin)$";
                diskKeyPathRegex = "^${prefix}\\/disk-key\\.enc\\.json$";
                roles =
                  lib.optionals
                  (cfg.idr ? roles)
                  (builtins.attrNames
                    (lib.filterAttrs (name: role: role.enable) cfg.idr.roles));
                name = hostName;
              }
          )
          (subDirectories config.idr.machineDirs));
      unlockServerRecipients = lib.concatMap (member:
        lib.optional
        (builtins.elem "unlock-server" (member.groups or []) && member ? agePublicKey)
        member.agePublicKey)
      (lib.attrValues top.self.lib.team);
      roles =
        lib.flatten
        (builtins.map
          (
            roleDir: let
              roleName = builtins.baseNameOf roleDir;
              prefix = lib.escape ["/" "-"] (lib.escapeRegex roleDir);
              metaFile = "${self}/${roleDir}/meta.json";
              hasConfig = builtins.pathExists metaFile;
              meta = lib.optionalAttrs hasConfig (lib.importJSON metaFile);
              roleId = meta.id;
              recipients = lib.flatten (lib.mapAttrsToList
                (
                  member_name: member:
                    lib.optional
                    (member ? groups && builtins.elem "role-${roleName}-${roleId}" member.groups && member ? agePublicKey)
                    member.agePublicKey
                )
                top.self.lib.team);
              relatedMachines = builtins.filter (machine: builtins.elem "${roleName}-${roleId}" machine.roles) machines;
            in
              lib.optional hasConfig {
                recipients =
                  lib.unique
                  (recipients ++ (lib.flatten (builtins.map (machine: machine.recipients) relatedMachines)));
                path_regex = "^${prefix}\\/.*\\.enc\\.(json|yaml|bin)$";
                name = roleName;
              }
          )
          (subDirectories config.idr.roleDirs));
    in
      (map (machine: {
          priority = 1;
          rule = {
            path_regex = machine.diskKeyPathRegex;
            age = lib.unique (machine.recipients ++ unlockServerRecipients);
          };
        })
        machines)
      ++ builtins.map ({
        recipients,
        path_regex,
        ...
      }: {
        rule = {
          inherit path_regex;
          age = recipients;
        };
      })
      (machines ++ roles);
  };
}

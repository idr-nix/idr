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
            nu -n --no-std-lib --no-history ${scripts}/idr-sops-updatekeys.nu --pending
            nu -n --no-std-lib --no-history ${scripts}/idr-write-last-changed-files-metadata.nu
            nu -n --no-std-lib --no-history ${scripts}/idr-sops-write-rotation-metadata.nu
          ''}
        '';
      };
      devshell.startup.idr-sops-clean-host-keys = {
        deps = ["idr-write-files"];
        text = let
          # Reuse this evaluation (including input overrides). Keep project
          # paths relative so cleanup reads the working tree's current secrets.
          machineSecrets = lib.mapAttrs (_: machine: let
            file = machine.config.idr.preset.base.defaultSopsFile or null;
            projectPrefix = "${self}/";
          in
            if file == null
            then null
            else if lib.hasPrefix projectPrefix (toString file)
            then builtins.unsafeDiscardStringContext (lib.removePrefix projectPrefix (toString file))
            else toString file)
          (self.nixosConfigurations or {});
          machineSecretsFile = pkgs.writeText "idr-machine-secrets.json" (builtins.toJSON machineSecrets);
        in ''
          nu -n --no-std-lib --no-history ${scripts}/idr-sops-clean-host-keys.nu ${machineSecretsFile}
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
      machineRecipient = machine: let
        name = machine.config.networking.hostName or "<unnamed>";
        file = machine.config.idr.preset.base.defaultSopsFile or null;
        secrets = lib.optionalAttrs (file != null && lib.hasSuffix ".json" file) (lib.importJSON file);
      in
        secrets.ssh_host_ed25519_key_age_pub_unencrypted
        or (throw "SOPS recipient machine ${name} must have ssh_host_ed25519_key_age_pub_unencrypted in its idr.preset.base.defaultSopsFile.");
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
                recipients = lib.unique (
                  recipients
                  ++ map machineRecipient (cfg.idr.preset.base.sopsRecipientMachines or [])
                  ++ (
                    lib.optional
                    (sops ? ssh_host_ed25519_key_age_pub_unencrypted)
                    sops.ssh_host_ed25519_key_age_pub_unencrypted
                  )
                );
                path_regex = "^${prefix}\\/.*\\.enc\\.(json|yaml|bin)$";
                diskKeyPathRegex = "^${prefix}\\/disk-key\\.enc\\.json$";
                dir = machineDir;
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
                dir = roleDir;
              }
          )
          (subDirectories config.idr.roleDirs));
      # Project files by their path below the project root, others as null.
      projectFile = file: let
        path = toString file;
      in
        if lib.hasPrefix "${self}/" path
        then lib.removePrefix "${self}/" path
        else null;
      defaultFiles = lib.concatMap (machine:
        map projectFile (
          lib.optional ((machine.config.idr.preset.base.defaultSopsFile or null) != null) machine.config.idr.preset.base.defaultSopsFile
          ++ lib.optional (machine.options.sops.defaultSopsFile.isDefined or false) machine.config.sops.defaultSopsFile
        ))
      (lib.attrValues (self.nixosConfigurations or {}));
      # A machine that reads a SOPS file of another machine or role directory
      # also becomes a recipient of that file, as do the machines of other
      # projects that its source lists. The file keeps the recipients of its
      # directory. Files outside the project, or outside machine and role
      # directories, follow their own rules.
      sharedFiles = lib.concatMap (reader: let
        machine = self.nixosConfigurations.${reader.name};
        defaultFile = machine.config.idr.preset.base.defaultSopsFile or null;
        # A machine without a key yet, such as one not installed, gets none.
        recipient =
          (lib.optionalAttrs (defaultFile != null && lib.hasSuffix ".json" (toString defaultFile)) (lib.importJSON defaultFile))
          .ssh_host_ed25519_key_age_pub_unencrypted
          or null;
      in
        lib.concatMap (source: let
          file = projectFile source.file;
          owner = lib.findFirst (entry: lib.hasPrefix "${entry.dir}/" file) null (machines ++ roles);
          added =
            lib.optional (recipient != null && !(builtins.elem recipient owner.recipients)) recipient
            ++ map machineRecipient source.recipientMachines;
        in
          lib.optional (file != null && owner != null && added != []) (
            # The added recipients can decrypt the whole file.
            if builtins.elem file defaultFiles
            then throw "${file} is the default SOPS file of a machine, but a secret of ${reader.name} shares it with other machines, which could then decrypt all of it. Keep secrets shared with other machines in a file of their own."
            else {
              inherit file;
              recipients = owner.recipients ++ added;
            }
          ))
        (machine.config.idr.secrets-sops-files or []))
      machines;
    in
      lib.mapAttrsToList (file: entries: {
        priority = 1;
        rule = {
          path_regex = "^${lib.escape ["/" "-"] (lib.escapeRegex file)}$";
          age = lib.unique (lib.concatMap (entry: entry.recipients) entries);
        };
      }) (lib.groupBy (entry: entry.file) sharedFiles)
      ++ (map (machine: {
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

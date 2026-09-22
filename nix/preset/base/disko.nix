top: moduleArgs @ {
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
  defaultSopsContent =
    lib.optionalAttrs (cfg.base.defaultSopsFile != null)
    (builtins.fromJSON (builtins.readFile cfg.base.defaultSopsFile));
in {
  options.idr.preset.base = {
    preFormatFiles = lib.mkOption {
      description = ''
        Copy the files to the VM, before disko is run. (used by idr-anywhere and other scripts)
        This is useful to provide secrets like LUKS keys, or other files you need for formatting
      '';
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          path = lib.mkOption {
            description = ''
              Path on the VM.
            '';
            type = lib.types.path;
            default = name;
          };
          sopsFile = lib.mkOption {
            description = ''
              Path to a sops file.
            '';
            type = lib.types.path;
            default = cfg.base.defaultSopsFile;
          };
          key = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Key to extract from the SOPS file, or null to decrypt the entire file.
            '';
          };
        };
      }));
      default = {};
    };
    postFormatFiles = lib.mkOption {
      description = ''
        Copy the files on the finished image. (used by idr-anywhere and other scripts)
        These end up in the images later and is useful if you want to add some extra stateful files
        They will have the same permissions but will be owned by root:root
      '';
      type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
        options = {
          path = lib.mkOption {
            description = ''
              Path on the VM.
            '';
            type = lib.types.path;
            default = name;
          };
          sopsFile = lib.mkOption {
            description = ''
              Path to a sops file.
            '';
            type = lib.types.path;
            default = cfg.base.defaultSopsFile;
          };
          key = lib.mkOption {
            description = ''
              Key used to lookup in the sops file.
            '';
          };
        };
      }));
      default = {};
    };
  };

  config = lib.mkIf (cfg.base.enable && !config.boot.isContainer) (lib.mkMerge [
    {
      system.build.idr.meta = {
        machine = config.networking.hostName;
        machineId = cfg.base.id;
        system = pkgs.stdenv.hostPlatform.system;
        inherit (cfg.base) defaultSopsFile;
        inherit (config.system.build) formatMount diskoScript toplevel;
        nixSettings = {inherit (config.nix.settings) substituters trusted-public-keys;};
        sshHostPublicKey = defaultSopsContent.ssh_host_ed25519_key_pub_unencrypted or null;
        initrdHostPublicKey = defaultSopsContent.initrd_ssh_host_ed25519_key_pub_unencrypted or null;
        initrdHostPublicKeys =
          lib.optional (defaultSopsContent ? initrd_ssh_host_ed25519_key_pub_unencrypted) defaultSopsContent.initrd_ssh_host_ed25519_key_pub_unencrypted
          ++ (defaultSopsContent.initrd_ssh_host_ed25519_key_pub_history_unencrypted or []);
        initrdPort = config.boot.initrd.network.ssh.port;
      };
      system.build.idr.meta.disko =
        (import ./qemu/disks.nix {
          inherit lib;
          diskDevices = config.disko.devices.disk or {};
        })
        // {
          inherit (cfg.base) preFormatFiles postFormatFiles;
          inherit (cfg.base.inputs) self;
          inherit (config.networking) hostId;
          hostIdIsBigEndian = pkgs.stdenv.hostPlatform.isBigEndian;
        };
    }
    {
      assertions = let
        diskDevices = config.disko.devices.disk or {};
        imageNames = map (diskCfg: diskCfg.imageName) (builtins.attrValues diskDevices);
      in
        lib.mapAttrsToList (diskName: diskCfg: {
          assertion =
            (builtins.match "[A-Za-z0-9_.][A-Za-z0-9._-]*" diskCfg.imageName)
            != null
            && !builtins.elem diskCfg.imageName ["." ".."];
          message = "disk ${diskName}: imageName `${diskCfg.imageName}` must be a safe basename using letters, digits, dots, underscores, or hyphens, and may not start with a hyphen";
        })
        diskDevices
        ++ [
          {
            assertion = builtins.length imageNames == builtins.length (lib.unique imageNames);
            message = "disko disk imageName values must be unique";
          }
        ];
    }
  ]);
}

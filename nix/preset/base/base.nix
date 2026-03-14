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
  imports = top.idr-lib.importApplyAll top [
    ./nixos-containers.nix
    ./podman.nix
    ./openssh.nix
    ./network.nix
    ./nixos-version.nix
    ./zfs.nix
    ./fail2ban.nix
    ./dbus.nix
    ./audit.nix
    ./nix.nix
    ./systemd.nix
    ./serial-console.nix
    ./boot.nix
    ./sudo.nix
    ./disko.nix
    ./key-rotation.nix
    ./qemu.nix
  ];
  options.system.build.idr = lib.mkOption {
    internal = true;
    default = {};
    type = lib.types.submodule {
      freeformType = lib.types.lazyAttrsOf (lib.types.uniq lib.types.unspecified);
      options.meta = lib.mkOption {
        type = lib.types.lazyAttrsOf lib.types.raw;
        default = {};
        description = "Metadata published by IDR features for deployment tools.";
      };
    };
  };
  options.idr.preset.base = {
    enable = lib.mkOption {
      description = ''
        Whether to enable base settings.
      '';
      type = lib.types.bool;
      default = cfg.base.id != null;
      defaultText = lib.literalExpression "config.idr.preset.base.id != null";
    };
    id = lib.mkOption {
      description = ''
        Machine identifier, 12 hexadecimal digits.

        Used to distinguish machines that share a name, e.g. in team group names
        (`host-<machine-name>-<id>`). The first 8 digits are used as `networking.hostId`.
      '';
      type = lib.types.nullOr (lib.types.strMatching "[0-9a-f]{12}");
      default = null;
      example = "1e6f6e96b47c";
    };
    inputs = lib.mkOption {
      description = ''
        Flake inputs.
      '';
      type = lib.types.attrsOf lib.types.unspecified;
      default = {};
    };
    defaultSopsFile = lib.mkOption {
      description = ''
        Path to a sops file.
      '';
      type = lib.types.nullOr lib.types.path;
      default = null;
    };
  };

  config = lib.mkIf cfg.base.enable {
    assertions = [
      {
        assertion = config.boot.isContainer || cfg.base.id != null;
        message = "idr.preset.base.id must be set when idr.preset.base.enable is true.";
      }
    ];

    users.mutableUsers = lib.mkDefault false;
    # Containers are administered through the host and can keep root locked.
    users.allowNoPasswordLogin = lib.mkDefault config.boot.isContainer;

    users.users.root =
      lib.optionalAttrs (
        !config.boot.isContainer
        && (defaultSopsContent ? root_password_hash_unencrypted)
      ) {
        hashedPassword = lib.mkDefault defaultSopsContent.root_password_hash_unencrypted;
      };

    hardware.enableRedistributableFirmware = lib.mkDefault (!config.boot.isContainer);

    boot.kernel.sysctl = {
      "kernel.panic_on_oops" = lib.mkDefault 1;
      "kernel.panic" = lib.mkDefault 10;
    };

    # Offer a password-protected recovery shell when a serial console exists.
    systemd.enableEmergencyMode = lib.mkDefault (
      !config.boot.isContainer && cfg.base.serialConsole.enable
    );

    # Build time dependencies necessary for offline rebuilds.
    system.extraDependencies =
      [
        (pkgs.writeStringReferencesToFile config.environment.extraSetup)
        config.system.nixos-init.package # for offline rebuild after change networking.hostId
      ]
      ++ (lib.optional config.documentation.info.enable pkgs.texinfo)
      ++ (lib.optionals config.networking.nftables.enable (with pkgs.buildPackages; [
        libredirect
        lklWithFirewall.lib
      ]))
      ++ (with pkgs; [
        lndir # build dependency of various packages including systemd and nix.
        kmod.inputDerivation # build dependency of initrd.
      ])
      ++ (lib.optional (cfg.base.inputs ? self) cfg.base.inputs.self)
      ++ top.idr-lib.collectFlakeInputs top.inputs;
  };
}

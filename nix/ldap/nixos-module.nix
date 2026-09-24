top: {
  config,
  lib,
  ...
}: let
  instances = lib.filterAttrs (_: instance: instance.enable) config.idr.ldap;
  userFields = lib.genAttrs [
    "uid"
    "firstName"
    "lastName"
    "mail"
    "sshPublicKey"
    "agePublicKey"
    "uidNumber"
    "gidNumber"
    "hashedPassword"
    "groups"
  ] (_: null);
  teamUsers = lib.mapAttrs (_: member:
    lib.mapAttrs (_: value: lib.mkDefault value) (lib.intersectAttrs userFields member))
  (lib.filterAttrs (_: member: !(member.system or false)) top.idr-lib.team);
  secrets = instance: {
    cert = instance.cert;
    cert-key = instance.certKey;
    root-password = instance.rootPassword;
  };
  allowedSources = lib.concatMap (instance:
    map (address: {
      inherit address;
      inherit (instance) port;
      ipv6 = lib.hasInfix ":" address;
    })
    instance.allowedIPs)
  (lib.attrValues instances);
in {
  key = toString ./nixos-module.nix;

  options.idr.ldap = lib.mkOption {
    default = {};
    description = "Declarative LDAPS directories, each running in its own NixOS container.";
    type = lib.types.attrsOf (lib.types.submodule ({config, ...}: {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to run this LDAP instance.";
        };
        cert = lib.mkOption {
          type = top.idr-lib.types.secret;
          description = "TLS certificate chain in PEM format.";
        };
        certKey = lib.mkOption {
          type = top.idr-lib.types.secret;
          description = "TLS private key in PEM format.";
        };
        rootPassword = lib.mkOption {
          type = top.idr-lib.types.secret;
          description = "LDAP administrator password hash, for example from slappasswd.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 636;
          description = "LDAPS listening port on the host network.";
        };
        allowedIPs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "IPv4 or IPv6 addresses or CIDR ranges allowed through the host firewall.";
        };
        secondLevelDomain = lib.mkOption {
          type = lib.types.str;
          example = "example";
          description = "First domain component of the directory suffix.";
        };
        topLevelDomain = lib.mkOption {
          type = lib.types.str;
          example = "com";
          description = "Second domain component of the directory suffix.";
        };
        domain = lib.mkOption {
          type = lib.types.str;
          default = "ldap.${config.secondLevelDomain}.${config.topLevelDomain}";
          defaultText = lib.literalExpression ''"ldap.''${config.secondLevelDomain}.''${config.topLevelDomain}"'';
          description = "DNS name for local access to this instance.";
        };
        users = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule (import ./user.nix));
          default = {};
          description = ''
            Directory users. LDAP fields from non-system team members are supplied as defaults;
            individual fields can be overridden and additional users can be added.
            Use lib.mkForce to replace the complete user set.
          '';
        };
      };
      config.users = teamUsers;
    }));
  };

  config = lib.mkIf (instances != {}) {
    networking.hosts."127.0.0.1" = map (instance: instance.domain) (lib.attrValues instances);

    networking.firewall = {
      extraInputRules = lib.mkIf config.networking.nftables.enable (lib.concatMapStringsSep "\n"
        (source: ''${
            if source.ipv6
            then "ip6"
            else "ip"
          } saddr ${source.address} tcp dport ${toString source.port} accept'')
        allowedSources);
      extraCommands = lib.mkIf (!config.networking.nftables.enable) (lib.concatMapStringsSep "\n"
        (source: ''${
            if source.ipv6
            then "ip6tables"
            else "iptables"
          } -A nixos-fw -s ${lib.escapeShellArg source.address} -p tcp --dport ${toString source.port} -j nixos-fw-accept'')
        allowedSources);
    };

    containers = lib.mapAttrs' (name: instance:
      lib.nameValuePair "ldap-${name}" {
        autoStart = true;
        privateUsers = "no";
        privateNetwork = false;
        bindMounts = lib.mapAttrs' (name: secret:
          lib.nameValuePair "/run/idr-ldap/${name}" {
            hostPath = toString secret.path;
            isReadOnly = true;
          }) (secrets instance);
        config = {
          imports = [(import ./instance.nix instance)];
        };
      })
    instances;

    systemd.services = lib.mapAttrs' (name: instance: let
      targets = lib.unique (map (secret: secret.restartTarget) (lib.attrValues (secrets instance)));
    in
      lib.nameValuePair "container@ldap-${name}" {
        wants = targets;
        after = targets;
        # Restarting refreshes bind mounts after a secret's symlink is replaced.
        partOf = targets;
      })
    instances;
  };
}

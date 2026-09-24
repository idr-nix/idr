top: moduleArgs @ {
  config,
  pkgs,
  lib,
  ...
}: let
  services = config.idr.systemd.services;
  envSecret = name: config.idr.secrets."${name}-env";
in {
  key = toString ./nixos-module.nix;

  options.idr.systemd.services = lib.mkOption {
    default = {};
    description = "Environment variables for systemd services, including values read from secrets.";
    type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
      options = {
        reloadOnEnvironmentChange = lib.mkOption {
          type = lib.types.bool;
          default = let
            service = moduleArgs.config.systemd.services.${name};
          in
            service.reload != "" || (service.serviceConfig ? ExecReload && toString service.serviceConfig.ExecReload != "");
          defaultText = "Whether the service defines a reload command.";
          description = "Whether to reload instead of restart the service when a secret value changes.";
        };
        environment = lib.mkOption {
          type = lib.types.attrsOf (lib.types.oneOf [
            top.idr-lib.types.secret
            lib.types.str
            lib.types.number
            lib.types.bool
          ]);
          default = {};
          description = ''
            Environment variables of the service. Secret references are read at
            runtime with trailing newlines removed; booleans become "true" or
            "false", and numbers become strings.
          '';
          example = lib.literalExpression ''
            {
              API_URL = "https://example.com";
              API_TOKEN = config.idr.secrets.api-token;
              WORKERS = 4;
              DEBUG = false;
            }
          '';
        };
      };
    }));
  };

  config = lib.mkIf (services != {}) {
    idr.secrets-source = lib.concatMapAttrs (name: service: {
      "${name}-env" = rec {
        secrets = lib.filterAttrs (_: top.idr-lib.isSecret) service.environment;
        exec = ''
          ${pkgs.jq}/bin/jq -rn \
            '$ARGS.positional[] as $name | $name + "=" + ($ENV[$name] | sub("\n+$"; "") | @sh)' \
            --args ${lib.escapeShellArgs (builtins.attrNames secrets)}
        '';
      };
    })
    services;

    systemd.services = lib.mapAttrs (name: service: let
      secret = envSecret name;
    in {
      serviceConfig = {
        EnvironmentFile = [secret.path];
        SupplementaryGroups = [config.users.groups.keys.name secret.group];
      };
      requires = ["idr-secrets.service"];
      after = ["idr-secrets.service" secret.reloadTarget secret.restartTarget];
      partOf = [
        (
          if service.reloadOnEnvironmentChange
          then secret.reloadTarget
          else secret.restartTarget
        )
      ];
      environment =
        lib.mapAttrs (_: value:
          if builtins.isBool value
          then lib.boolToString value
          else toString value)
        (lib.filterAttrs (_: value: !(top.idr-lib.isSecret value)) service.environment);
    })
    services;
  };
}

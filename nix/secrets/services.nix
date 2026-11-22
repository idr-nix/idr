# Modular services declare secrets like the machine does: a service's
# idr.secrets-source.<name> becomes the machine's svc-<service>--<name>, and
# the service reads the result from its own idr.secrets.<name>.
top: {
  config,
  lib,
  ...
}: let
  machine = config;
  # Names of nested services, joined as nixpkgs joins their unit names.
  serviceName = parent: name:
    if parent == ""
    then name
    else if name == ""
    then parent
    else "${parent}-${name}";
  machineName = service: secret: "svc-${service}--${secret}";

  serviceModule = parent: {
    name,
    config,
    ...
  }: let
    full = serviceName parent name;
  in {
    _class = "service";
    options = {
      idr.secrets-source = lib.mkOption {
        description = ''
          Secrets this service uses, each a secret reference or a secret source
          as in the machine's idr.secrets-source. The machine provides each as
          `svc-<service>--<name>`, where `<service>` is this service's name, joined
          with its parents' by `-` for nested services.
        '';
        type = lib.types.lazyAttrsOf top.idr-lib.types.secretOrSource;
        default = {};
      };
      idr.secrets = lib.mkOption {
        description = "Resolved secrets of this service's idr.secrets-source, providing paths and access control metadata.";
        type = lib.types.lazyAttrsOf top.idr-lib.types.secret;
        readOnly = true;
      };
      services = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submoduleWith {
          class = "service";
          modules = [(serviceModule full)];
        });
      };
    };
    config.idr.secrets = lib.mapAttrs (secret: _: machine.idr.secrets.${machineName full secret}) config.idr.secrets-source;
  };

  # Every service's secrets under their machine names, nested services included.
  collect = parent: name: service: let
    full = serviceName parent name;
  in
    lib.mapAttrsToList (secret: lib.nameValuePair (machineName full secret)) service.idr.secrets-source
    ++ lib.concatLists (lib.mapAttrsToList (collect full) service.services);
  declared = lib.concatLists (lib.mapAttrsToList (collect "") machine.system.services);
in {
  key = toString ./services.nix;

  options.system.services = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submoduleWith {
      class = "service";
      modules = [(serviceModule "")];
    });
  };

  config = {
    idr.secrets-source = lib.listToAttrs declared;
    assertions = [
      {
        assertion = lib.allUnique (map (entry: entry.name) declared);
        message = "Modular service secrets are provided as svc-<service>--<name>, which must be unique.";
      }
    ];
  };
}

top: {
  config,
  lib,
  ...
}: let
  cfg = config.idr.etcd;
  endpoints =
    lib.concatMap (client: client.endpoints)
    ((lib.attrValues (lib.filterAttrs (_: proxy: proxy.enable) cfg.proxy)) ++ cfg.rbac);
in {
  imports = top.idr-lib.importApplyAll top [
    ./options.nix
    ./server.nix
    ./proxy.nix
    ./rbac.nix
  ];

  config = lib.mkIf cfg.enable {
    networking.hosts = lib.zipAttrs (map (endpoint: {
      ${endpoint.ip} = endpoint.domain;
    }) (lib.filter (endpoint: endpoint.ip != null) endpoints));

    assertions =
      lib.concatMap (rbac: [
        {
          assertion = !(rbac.users ? root) && !(rbac.roles ? root);
          message = "idr.etcd.rbac: root is reserved for the administrator account and role.";
        }
        {
          assertion = lib.all (name: name != "" && !(lib.hasInfix ":" name)) (lib.attrNames rbac.users);
          message = "idr.etcd.rbac: user names must be nonempty and may not contain ':'.";
        }
        {
          assertion = lib.all (role:
            lib.all (permission:
              !permission.prefix || builtins.isString permission.target)
            role.permissions) (lib.attrValues rbac.roles);
          message = "idr.etcd.rbac: prefix permissions require a string target.";
        }
        {
          assertion = lib.all (role:
            lib.all (permission:
              builtins.isString permission.target || permission.target.from != "")
            role.permissions) (lib.attrValues rbac.roles);
          message = "idr.etcd.rbac: range permissions require a nonempty 'from' key; use prefix = true for the entire keyspace.";
        }
      ])
      cfg.rbac;
  };
}

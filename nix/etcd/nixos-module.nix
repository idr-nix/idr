top: {
  config,
  lib,
  ...
}: let
  cfg = config.idr.etcd;
  rbac = lib.filterAttrs (_: cluster: cluster.rbac != null) cfg.clusters;
  endpoints =
    lib.concatMap (client: client.endpoints)
    ((lib.attrValues (lib.filterAttrs (_: proxy: proxy.enable) cfg.proxy))
      ++ map (cluster: cluster.rbac) (lib.attrValues rbac));
in {
  key = toString ./nixos-module.nix;

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
      [
        {
          assertion =
            lib.all (name: builtins.match "[A-Za-z0-9_.-]+" name != null)
            (lib.attrNames cfg.clusters
              ++ lib.concatMap (cluster: lib.attrNames cluster.instances) (lib.attrValues cfg.clusters));
          message = "idr.etcd: cluster and member names must be nonempty and contain only letters, digits, '_', '.', or '-'.";
        }
      ]
      ++ lib.concatLists (lib.mapAttrsToList (name: cluster: let
          rbac = cluster.rbac;
          option = "idr.etcd.clusters.${name}.rbac";
        in [
          {
            assertion = !(rbac.users ? root) && !(rbac.roles ? root);
            message = "${option}: root is reserved for the administrator account and role.";
          }
          {
            assertion = lib.all (name: name != "" && !(lib.hasInfix ":" name)) (lib.attrNames rbac.users);
            message = "${option}: user names must be nonempty and may not contain ':'.";
          }
          {
            assertion = lib.all (user:
              lib.all (role: role == "root" || builtins.hasAttr role rbac.roles) user.roles)
            (lib.attrValues rbac.users);
            message = "${option}: users may only reference declared roles or the built-in root role.";
          }
          {
            assertion = lib.all (role:
              lib.all (permission:
                !permission.prefix || builtins.isString permission.target)
              role.permissions) (lib.attrValues rbac.roles);
            message = "${option}: prefix permissions require a string target.";
          }
          {
            assertion = lib.all (role:
              lib.all (permission:
                builtins.isString permission.target || permission.target.from != "")
              role.permissions) (lib.attrValues rbac.roles);
            message = "${option}: range permissions require a nonempty 'from' key; use prefix = true for the entire keyspace.";
          }
        ])
        rbac);
  };
}

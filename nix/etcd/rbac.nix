top: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.etcd;
  reconcile = pkgs.writers.writeNu "idr-etcd-rbac" (builtins.readFile ./setup-users.nu);
  userCredential = name: "user-${top.idr-lib.shortHash 16 name}";
in {
  config = lib.mkIf cfg.enable {
    systemd.services = builtins.listToAttrs (map (rbac: let
      endpoints = lib.concatStringsSep "," (map (endpoint: "https://${top.idr-lib.normalizeHost endpoint.domain}:${toString endpoint.port}") rbac.endpoints);
      name = "idr-etcd-rbac-${top.idr-lib.shortHash 8 endpoints}";
      passwords = [rbac.rootPassword] ++ map (user: user.password) (lib.attrValues rbac.users);
      restartTargets = lib.unique (map (password: password.restartTarget) passwords);
      settings = pkgs.writers.writeJSON "${name}.json" {
        inherit (rbac) roles;
        users =
          lib.mapAttrs (name: user: {
            inherit (user) roles;
            password = userCredential name;
          })
          rbac.users;
      };
    in
      lib.nameValuePair name {
        description = "Reconcile etcd users and roles";
        wantedBy = ["multi-user.target"];
        wants = ["network-online.target"] ++ restartTargets;
        after = ["network-online.target"] ++ restartTargets;
        partOf = restartTargets;
        path = [rbac.package];
        environment =
          {
            ETCDCTL_ENDPOINTS = endpoints;
            ETCDCTL_WRITE_OUT = "json";
            ETCDCTL_DIAL_TIMEOUT = "5s";
            ETCDCTL_COMMAND_TIMEOUT = "10s";
          }
          // lib.optionalAttrs (rbac.caCert != null) {
            ETCDCTL_CACERT = toString rbac.caCert;
          };
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig = {
          Type = "oneshot";
          # Keep the unit active so password restart targets rerun reconciliation.
          RemainAfterExit = true;
          ExecStart = "${reconcile} ${settings}";
          Restart = "on-failure";
          RestartSec = "5s";
          TimeoutStartSec = "300s";
          DynamicUser = true;
          LoadCredential =
            ["root-password:${rbac.rootPassword.path}"]
            ++ lib.mapAttrsToList (name: user: "${userCredential name}:${user.password.path}") rbac.users;
          PrivateTmp = true;
          ProtectHome = true;
          UMask = "0077";
        };
      })
    cfg.rbac);
  };
}

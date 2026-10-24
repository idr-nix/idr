{top}: {lib, ...}: {
  imports = [(lib.modules.importApply ./etcd-fixture.nix {inherit top;})];
  nodes.alpha = {config, ...}: {
    idr.secrets-source = lib.genAttrs ["root-password" "application-password"] (_: {
      sopsFile = ./fixtures/etcd/initial.enc.json;
      format = "json";
    });
    idr.etcd.clusters.main.rbac = {
      endpoints = map (name: {domain = "etcd-${name}.example.test";}) ["alpha" "beta" "gamma"];
      caCert = ./fixtures/etcd/ca.pem;
      rootPassword = config.idr.secrets.root-password;
      roles = {
        application.permissions = [
          {
            target = "/application/";
            prefix = true;
            access = "readwrite";
          }
        ];
        audit.permissions = [
          {target = "/status";}
          {
            target = {
              from = "/range/a";
              to = "/range/z";
            };
          }
          {
            target = "/write-only";
            access = "write";
          }
        ];
        retired.permissions = [
          {
            target = "/retired/";
            prefix = true;
            access = "readwrite";
          }
        ];
      };
      users = {
        application = {
          password = config.idr.secrets.application-password;
          roles = ["application" "audit"];
        };
        retired = {
          password = config.idr.secrets.application-password;
          roles = ["retired"];
        };
      };
    };
  };
}

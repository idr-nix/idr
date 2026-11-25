# etcd users and roles for the mesh agents of the given machines in one of
# their `idr.mesh.etcd` clusters. Each machine gets its own user and role:
# read and write on the services it declares in the cluster, and read on their
# peers. Passwords come from the machines' SOPS sources.
{lib}: cluster: nixosConfigurations: let
  member = machine: (machine.config.idr.mesh.enable or false) && machine.config.idr.mesh.etcd ? ${cluster};
  access = map (machine: machine.config.idr.mesh.etcd.${cluster}.access) (
    lib.filter member (lib.attrValues nixosConfigurations)
  );
  users = map (machine: machine.user) access;
  permission = machine: kind: service: {
    target = "/idr/mesh/${machine.ipv6Prefix}/services/${service}/";
    prefix = true;
    access = kind;
  };
  byUser = machines: f: lib.listToAttrs (map (machine: lib.nameValuePair machine.user (f machine)) machines);
in
  assert lib.assertMsg (lib.allUnique users) "Each mesh machine needs its own etcd user."; {
    roles = byUser access (machine: {
      permissions = map (permission machine "readwrite") machine.write ++ map (permission machine "read") machine.read;
    });
    # A machine that passes a runtime secret leaves the password to the RBAC
    # host, which cannot read it from the machine's configuration.
    users = byUser access (machine:
      {roles = [machine.user];}
      // lib.optionalAttrs (machine.password != null) {inherit (machine) password;});
  }

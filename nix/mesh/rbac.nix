# etcd users and roles for the mesh agents of the given machines. Each machine
# gets its own user and role: read and write on the services it declares, and
# read on their peers. Passwords come from the machines' SOPS sources.
{lib}: nixosConfigurations: let
  access = map (machine: machine.config.idr.mesh.etcd.access) (
    lib.filter (machine: machine.config.idr.mesh.enable or false) (lib.attrValues nixosConfigurations)
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
      // lib.optionalAttrs (machine.passwordSource != null) {inherit (machine) passwordSource;});
  }

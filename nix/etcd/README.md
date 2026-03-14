## etcd

The etcd module provides cluster members connected through WireGuard, HTTPS
client endpoints, local gRPC proxies, and declarative users and roles.

### Cluster members

Configure an odd number of members, normally three, on separate hosts. For
example, this configures `alpha` in a cluster with `beta` and `gamma`:

```nix
idr.etcd = {
  privateNetwork = {
    listenPort = 61010;
    privKey = config.idr.secrets.etcd-wireguard-key;
    peers = [
      {
        endpoint = { address = "192.0.2.12"; port = 61010; };
        pubKey = "<beta WireGuard public key>";
        psk = config.idr.secrets.etcd-alpha-beta-psk;
        etcdPeers = ["beta"];
      }
      {
        endpoint = { address = "2001:db8::13"; port = 61010; };
        pubKey = "<gamma WireGuard public key>";
        psk = config.idr.secrets.etcd-alpha-gamma-psk;
        etcdPeers = ["gamma"];
      }
    ];
  };
  instances.alpha = {
    dataDir = "/p1/etcd-alpha";
    cert = config.idr.secrets.etcd-cert;
    certKey = config.idr.secrets.etcd-cert-key;
    clusterToken = "application-etcd";
    publicHostname = "etcd-alpha.example.com";
    publicPort = 2379;
    allowedIPs = ["192.0.2.0/24" "2001:db8::/64"];
    peers = { beta = {}; gamma = {}; };
  };
};
```

Configure the other hosts with their own member names, certificates, WireGuard
keys, and peer lists. Use the same `clusterToken` across the cluster and the
same preshared key for each pair of hosts.
Member names determine their private IPv6 addresses and must be unique across
clusters sharing the network.

Create and mount the `dataDir` dataset in the machine configuration. The module
bind-mounts it at `/var/lib/private/idr-etcd-<name>` and runs etcd with
`DynamicUser` and `StateDirectory`. See [persistent storage](../preset/README.md#persistent-data).

Use [IDR secret references](../secrets/README.md) for certificates and private
keys. `allowedIPs` controls access to the HTTPS client port.

Start the configured members to bootstrap the cluster. Changing `peers` does
not update membership in an existing database; use etcd's
[runtime membership operations](https://etcd.io/docs/v3.6/op-guide/runtime-configuration/)
when adding or removing members.

### Users and roles

Configure one RBAC controller per cluster. For example:

```nix
idr.etcd.rbac = [
  {
    endpoints = [
      { domain = "etcd-alpha.example.com"; }
      { domain = "etcd-beta.example.com"; }
      { domain = "etcd-gamma.example.com"; }
    ];
    rootPassword = config.idr.secrets.etcd-root-password;
    roles.application.permissions = [
      { target = "/application/"; prefix = true; access = "readwrite"; }
    ];
    users.application = {
      password = config.idr.secrets.etcd-application-password;
      roles = ["application"];
    };
  }
];
```

The controller enables authentication in a new cluster and applies user
passwords, role assignments, and permissions on deployment or secret changes.
It removes undeclared users and roles, except the built-in `root` account and
role.

After bootstrap, `rootPassword` must match the existing administrator password.
Enable RBAC before allowing application clients to connect.

A permission's `target` can be an exact key, a string with `prefix = true`, or
`{ from = "/first"; to = "/last"; }` for an inclusive start and exclusive end.
`access` accepts `read`, `write`, or `readwrite` and defaults to `read`.

Endpoint ports default to `2379`. An endpoint's optional `ip` adds a local hosts
entry for its `domain`. Set `caCert` to a public CA file when the cluster uses a
private CA; otherwise the controller uses system trust.

### Local proxy

For example, expose a cluster locally as `http://application.etcd.internal:65535`:

```nix
idr.etcd.proxy.application = {
  endpoints = [
    { domain = "etcd-alpha.example.com"; }
    { domain = "etcd-beta.example.com"; }
    { domain = "etcd-gamma.example.com"; }
  ];
};
```

The proxy binds to its own local IPv6 address and connects to the HTTPS
endpoints. Clients still supply their etcd credentials. The endpoint and
`caCert` options are the same as for RBAC; `extraArgs` accepts additional
`etcd grpc-proxy start` arguments.

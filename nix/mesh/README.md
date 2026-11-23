## Service mesh

Configure each machine's advertised addresses and etcd credentials:

```nix
idr.mesh = {
  enable = true;
  publicAddresses = ["2001:db8::10" "203.0.113.10"];
  etcd = {
    endpoint = "http://main.etcd.internal:1023";
    username = "mesh-${config.networking.hostName}";
    password = {
      sopsFile = ./mesh-etcd.enc.json;
      key = "password";
    };
  };
};
```

Configure the [local proxy](../etcd/README.md#local-proxy) through the etcd
module. The password and peer PSKs accept a
[secret reference or source](../secrets/README.md#secret-references-or-sources).

Keep each machine's password in a SOPS file of its own: the RBAC machines read
it and become recipients of the file. List RBAC machines of other projects in
the password's `recipientMachines`. A password passed as a reference stays
local, so also set that user's `password` on the RBAC machines.

On the RBAC machines, derive the etcd
[users and roles](../etcd/README.md#users-and-roles):

```nix
idr.etcd.clusters.main.rbac = lib.mkMerge [
  {...}
  (inputs.idr.lib.meshRbac self.nixosConfigurations)
];
```

Leave `publicAddresses` empty (the default) to discover publicly routable host
addresses.

`portRange` defaults to `30000`-`32767`. The first port is reserved for UDP health
checks; WireGuard instances use the remaining ports.

`ipv6Prefix` defaults to `fdb4:cb46:0ef1`. Use the same prefix on all machines
in the mesh.

Add mesh settings to an existing modular service:

```nix
system.services."222222222222" = {...}: {
  imports = [inputs.idr.modules.service.mesh];

  idr.mesh.id = "222222222222";
  idr.mesh.peers."333333333333".psk =
    config.idr.secrets."222222222222-333333333333-psk";
};
```

Configure the other service with ID `333333333333`, peer `222222222222`, and the
same PSK. Replicas share the service ID and peer declarations. To declare peering
between replicas, add the service's own ID to `peers`.

Use `333333333333.mesh` to reach the peer's instances.

### Published ports

Forward ports of the host's addresses to a workload:

```nix
idr.mesh.publish = [
  {proto = "tcp"; port = 443;}
  {proto = "udp"; port = 443;}
  {proto = "udp"; port = {from = 50000; to = 60000;};}
];
```

Connections from other machines keep the client's address. The workload still
cannot open connections other than to its peers. Changing the ports does not
restart the workload. Publishing needs the nftables firewall with
`networking.firewall.filterForward`, both on in the base preset, and Linux 6.17
or later. Each port and protocol belongs to one workload per machine, so ports
and ranges must not overlap.

If the link addresses overlap a local network, change
`idr.mesh.published.ipv4Prefix` (default `10.201`, a /16) or
`idr.mesh.published.ipv6Prefix`.

### Internet access

Allow a workload to open connections to the internet:

```nix
idr.mesh.internet = {
  enable = true;
  allow = [
    {proto = "tcp"; port = 443;}
    {proto = "udp"; port = {from = 10000; to = 20000;}; destinations = ["203.0.113.0/24"];}
  ];
};
```

The connections leave with the host's address; others fail at once. Without
`destinations`, any address is allowed. The workload resolves names outside the
mesh with the machine's `idr.mesh.internet.nameservers`, by default
`networking.nameservers`. Changing the access does not restart the workload. Like
published ports, it needs the nftables firewall with
`networking.firewall.filterForward` and Linux 6.17 or later.

### Monitoring

Run `idr-mesh status` as root to print each workload's mesh state as JSON.

To export the same state to Prometheus, point the mesh at node-exporter's
textfile directory:

```nix
idr.mesh.metrics.textfileDirectory = "/var/lib/node-exporter-textfile";
services.prometheus.exporters.node = {
  enable = true;
  enabledCollectors = ["textfile"];
  extraFlags = ["--collector.textfile.directory=/var/lib/node-exporter-textfile"];
};
```

Alert when, for several minutes:

- `idr_mesh_workload_up == 1` but `idr_mesh_workload_registered == 0`: the
  agent cannot register the workload in etcd.
- `idr_mesh_applied_revision != idr_mesh_discovered_revision`: netd does not
  apply discovered peers.
- `idr_mesh_psk_mismatches > 0`: a peer's PSK has not converged.
- `idr_mesh_wireguard_recent_handshakes < idr_mesh_wireguard_peers`: some peers
  are unreachable.
- `idr_mesh_public_addresses == 0`: the host advertises no address.
- `time() - node_textfile_mtime_seconds{file=~".*idr-mesh.prom"} > 120`: the
  mesh metrics are stale.

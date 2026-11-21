## Mesh operations

Run these commands as root on a mesh host. See the [service mesh guide](../nix/mesh/README.md)
for setup.

### Check a host

```sh
idr-mesh status
```

Every up workload should be registered, and its applied revision should equal its
discovered revision. The [monitoring](../nix/mesh/README.md#monitoring) alerts
watch the same state.

### Rotate a PSK

Change the PSK secret of both services to the new key and deploy their machines
in any order. Links keep the previous key until both ends have the new one.

### Revoke a peer link

Remove the peer from `idr.mesh.peers` of either service and deploy that machine.
Both ends drop the link.

### Where state lives

| Path | Contents |
|---|---|
| `/var/lib/idr-mesh-agent` | Each workload's instance ID and registration journal |
| `/var/lib/idr-mesh-psk` | Each workload's PSK key stores |
| `/run/idr-mesh-agent` | Peer snapshots and unhealthy endpoints |
| `/run/idr-mesh-apply`, `/run/idr-mesh-netd` | netd's applied state and published status |
| `/run/idr-mesh-keys` | WireGuard keys, new on each boot or stop |

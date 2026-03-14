## Backups

Backup servers pull ZFS snapshots over SSH. Source machines create snapshots with
Sanoid; Syncoid replicates each configured pool root and its children.

Machines using the base preset take local snapshots of their Disko ZFS pools
using the `idr_short_term` Sanoid policy, even without a backup server.

### Register a backup server

Add the backup server as a [system team member](../../docs/team-input.md#system-members):

```toml
["backup-machine-<machine-id>"]
system = true
groups = ["backup-server"]
sshPublicKey = "<backup-server-public-key>"
```

Use `ssh_host_ed25519_key_pub_unencrypted` from the backup server's machine
`secrets.enc.json`. Update the team input and deploy the source machines.

For machines using the base preset and Disko ZFS pools, this automatically:

- Creates the `idr-backup` account and authorizes the backup servers' SSH keys.
- Delegates ZFS `send` and `hold` permissions on pool roots and their descendants,
  without sudo or permissions to create, delete, or roll back snapshots.

Holds keep snapshots available while an incremental transfer reads them.

### Configure the backup server

Add the source projects as flake inputs. In the backup server's role configuration:

```nix
idr.backup.server = {
  enable = true;
  dataset = "p1/backups";
  nodes = [
    top.inputs.application.deploy.nodes.some-machine
  ];
};
```

The destination pool must already exist. IDR creates the destination dataset if
needed and uses the backup server's SSH host identity for authentication. Source
addresses, SSH options, host-key pins, and dataset roots come from deploy metadata.
Only listed nodes are backed up. The server skips itself and the generated
`vm-` nodes.

Backups are stored under `<destination>/<machine-name>-<machine-id>/<source-root>`.
Received datasets are read-only and are not mounted automatically. The destination
is marked `syncoid:sync=false` to exclude it from further backups.

Replication runs every five minutes. Change `idr.backup.server.interval` to use
another systemd calendar expression. Source and destination retention policies
can be adjusted through `services.sanoid.templates.idr_short_term` and
`services.sanoid.templates.idr_long_term`.

### Select datasets

Pool roots from Disko are included by default. Use
`idr.backup.client.datasets` to select different roots, or
`idr.backup.client.enable = false` to disable remote backup access.

Syncoid skips datasets with `syncoid:sync=false`, including children that inherit
the property. The generated layout already excludes its `local` subtree.
For another existing dataset:

```nix
disko.devices.zpool.p1.datasets.cache.options."syncoid:sync" = "false";
```

The generated layout excludes `p1/local/root` and `p1/local/nix` from local
snapshots using `idr:snapshots=false`. To exclude another dataset and its children:

```nix
disko.devices.zpool.p1.datasets.cache.options."idr:snapshots" = "false";
```

IDR generates Sanoid exclusions from this Disko setting during evaluation;
changing the live ZFS property alone does not update Sanoid. Excluded datasets
receive no automatic snapshots, and their existing snapshots are not pruned.
Set `services.sanoid.enable = false` to disable local snapshot management.

### Operation

To run a backup immediately on the backup server:

```sh
systemctl start "idr-backup-<machine-name>-<machine-id>.service"
```

Inspect failures with `systemctl --failed` and:

```sh
journalctl -u 'idr-backup-*'
```

When the backup server runs in local QEMU, it connects to source VMs in the same
workspace using their local IPv6 addresses and configured SSH ports.

After source host-key rotation, update the corresponding project input and deploy
the backup server. After rotating the backup server's host key, update its team
public key and deploy the source machines.

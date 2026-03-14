## Automatic disk unlocking

Unlock servers supply disk keys when machines boot into initrd. Server identities
and notification endpoints come from the [team input](../../docs/team-input.md#system-members).
Targets, SSH settings, and encrypted disk keys come from their deploy-rs configurations.

### Register an unlock server

Add a system team member named `<machine-name>-<machine-id>` with the
`unlock-server` group, its notification `hostname` and `port`, and its SSH and age
public keys. Use `ssh_host_ed25519_key_pub_unencrypted` and
`ssh_host_ed25519_key_age_pub_unencrypted` from that server's machine secrets.

Update the team input in the affected projects and enter their development
shells. IDR adds unlock-server recipients to `disk-key.enc.json` files. Other
machine secrets and role secrets keep their existing recipients.

### Enable the server

Add the projects to the unlock server's flake inputs. In its role configuration,
select the machines to unlock:

```nix
idr.disk-unlock.server = {
  enable = true;
  nodes = [
    top.inputs.project-a.deploy.nodes.machine-a
    top.inputs.project-b.deploy.nodes.machine-b
  ];
};
```

The server uses its Ed25519 SSH host identity to decrypt disk keys and
authenticate to initrd. It reads each selected node's address, SSH options,
initrd port, host-key pin, and disk-key source from the system profile metadata.
Local VM nodes and machines without SSH-unlock metadata are skipped.

The matching team member supplies the notification port (default: 64998).
`server.member` can select a different team record. Enabling the server opens
that TCP port; notifications can only trigger callbacks to configured targets.

### Client machines

The base preset enables requests automatically when a disk key and team unlock
servers are configured. It authorizes those servers' SSH keys only in initrd and
notifies each server independently, retrying every 30 seconds by default.
Local QEMU VMs use their runner's automatic unlock instead.

To disable requests for a machine, set `idr.disk-unlock.client.enable = false`.
Use `idr.disk-unlock.client.interval` to change the retry interval in seconds.
[Manual unlocking](../../docs/unlock-disks.md) remains available.

After rotating a target's keys, update the corresponding flake input on the
unlock server and deploy it to load the new disk key and initrd host-key pin.
When rotating an unlock server's host identity, update its team public keys,
refresh disk-key recipients in the client repositories, and deploy the updated
server and client configurations.

For server-side failures, inspect:

```sh
journalctl -u 'idr-disk-unlock@*'
```

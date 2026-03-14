## Rotate machine keys

`idr-rotate-keys` regenerates expired SSH host keys (normal and initrd) and the root
password in the machine's `secrets.enc.json`, and the disk key in `disk-key.enc.json`.
Run it from a development shell that can decrypt the machine's secrets and any
affected role secrets after rotation.

Use the deploy-rs node name to rotate, copy, and [deploy](deployment.md):

```sh
idr-rotate-keys some-machine
idr-copy-extra-files some-machine
deploy -s .#some-machine -- -L
```

Rotating the normal SSH host key also updates its SOPS recipient and rotates the
data keys in affected repository secret files. Application credentials such as API
tokens keep their values and must be rotated separately.

Add `--force` to `idr-rotate-keys` to rotate all managed keys immediately.

If you use an [unlock server](../nix/disk-unlock/README.md), update its input for
the machine's repository and redeploy the unlock server to load the rotated keys.

### Rotation intervals

A key is due when its interval has elapsed since `modified_ts` (Unix seconds),
recorded alongside the secret:

```json
{
  "disk_key@_unencrypted": "interval=90day modified_ts=1780973191"
}
```

To change a field's interval, edit its annotation through SOPS, preserving the
existing `modified_ts`:

```sh
sops nix/machine/some-machine/disk-key.enc.json
```

The default interval for new annotations is `90day`. Set
`IDR_ROTATION_DEFAULT_INTERVAL` to change that default; existing annotations keep
their intervals.

### Revoke old disk keys

Activation reads the disk key through SOPS and adds it to the managed LUKS2
devices: Disko devices with `initrdUnlock = true` whose `passwordFile` uses IDR's
configured disk-key path. Previous keys remain usable until you revoke them.
After deploying and verifying the new system, run:

```sh
idr-revoke-old-disk-keys some-machine
```

The command uses the running generation's disk key and verifies it on every
managed disk before removing any slots. It accepts `--host`, `--user`, and
`--port` overrides.

IDR marks its keyslots in the LUKS2 header and removes only older marked slots.
Unmarked slots, including manually added keys, are preserved.

### Rollback and recovery

SSH host keys use versioned persistent paths, so copying new keys preserves the
ones required by older generations.

Keep the encrypted recovery bundle (`/persist/var/lib/idr/disk-key-recovery/current`
in the default layout) and the retained SSH host keys.
They let older generations recover the valid disk key and add their own after
revocation.

Recovery runs after the disks are mounted. To boot an older generation, unlock
it using the currently valid disk key. `idr-unlock-disks` reads the key from the
current repository configuration; for a historical initrd SSH key, follow
[unlocking with an older host key](unlock-disks.md#older-initrd-host-keys).

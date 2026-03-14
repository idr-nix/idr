## Unlock disks over SSH

`idr-unlock-disks` decrypts the configured disk key with SOPS and sends it to the
initrd's SSH passphrase agent. Run it from the project development shell with
SOPS decryption access and an authorized SSH key:

```sh
idr-unlock-disks some-machine
```

The command takes a deploy-rs node name and uses its address and SSH options.
The default SSH user is `root`.

For unattended boots, configure an [automatic unlock server](../nix/disk-unlock/README.md).

### Connection options

Use `--host`, `--user`, or `--port` to override the connection. The default
timeout is five minutes; change it with `--timeout`:

```sh
idr-unlock-disks some-machine --host 192.0.2.10 --port 2222 --timeout 10min
```

Additional arguments are passed to SSH. For example, select an identity file
and connect through a jump host:

```sh
idr-unlock-disks some-machine -i ~/.ssh/id_ed25519 -o 'ProxyJump=jump.example.com'
```

### Local VMs

Local VMs unlock automatically by default. To test manual unlocking, run the
following with Process Compose stopped:

```sh
env IDR_QEMU_AUTO_UNLOCK=false idr -D
idr process start vm-some-machine
idr-unlock-disks vm-some-machine
```

### Older initrd host keys

By default, the command trusts the current configuration's initrd SSH host key.
To unlock an older boot generation after [key rotation](key-rotation.md), select
its recorded fingerprint explicitly. List the available fingerprints with:

```sh
nix eval --raw .#deploy.nodes.some-machine.profiles.system.path.idr.meta.initrdHostPublicKeys --apply 'builtins.concatStringsSep "\n"' | ssh-keygen -lf -
```

Pass the chosen value using `--host-key-fingerprint SHA256:…`.

## idr-mk-machine

Before creating a machine, it's recommended to configure your personal keys.

Add your information to the team configuration. The most important fields are:
- `sshPublicKey`
- `agePublicKey`
- `mail`

If you're using an `ed25519` SSH key, you can convert it to an age key:

```sh
# Convert SSH public key to age public key
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEjuIF2uXOUQyThLB6O5jmHCcz11uokg9XCAot+XHzM3" | nix shell nixpkgs#ssh-to-age -c ssh-to-age

# Convert SSH private key to age private key
nix shell nixpkgs#ssh-to-age -c ssh-to-age -i ~/.ssh/id_ed25519 -private-key
```

Next, configure environment variables:
- `IDR_SOPS_AGE_KEY_CMD` - Nushell command that outputs your age private key
- `IDR_USER` - your username from the team configuration

Keep your private key in a protected file or secret manager, and have
`IDR_SOPS_AGE_KEY_CMD` retrieve it.

Store these variables in `.env`.

---

https://xkcd.com/910/

Before creating a machine configuration, choose a **short, memorable, and distinctive name** for the server.

If you're unsure, you can generate one with:
```sh
nix shell nixpkgs#rust-petname -c petname
```

Naming guidelines:
- Use lowercase only
- Separate words with dashes (`-`)
- Avoid embedding metadata (e.g., project name or service role)

Metadata should be stored elsewhere because:
1. Servers may be repurposed
2. A single server can host multiple services  
   (roles are designed to be portable between machines)

---

Now you can create the machine configuration:

```sh
idr-mk-machine some-machine
```

This will generate the configuration in:
```
./nix/machine/<machine-name>
```

The idr-mk-machine command creates the following files in `./nix/machine/<machine-name>`:

1. `hardware-specific.nix` - sample disk layout and network configuration
2. `configuration.nix` - imports all modules and enables the base preset
3. `secrets.enc.json` - SSH host keys and the root password
4. `disk-key.enc.json` - the disk encryption key
5. `flake-module.nix` - registers configuration.nix for NixOS and deploy-rs

The generated host key can decrypt both secret files. It is initially stored in
plaintext in `.data/machine-host-key/<machine-name>` until operator access is
configured below. The disk key is also shared with configured
[unlock servers](../nix/disk-unlock/README.md).

---

Find the machine ID (`idr.preset.base.id`) in `configuration.nix`.

- For root SSH access, add an `sshAccess` entry in `team.toml`, using the
  machine's `networking.hostName` and ID as its key. Omit `expiresAt` for
  permanent access:

  ```toml
  [John.sshAccess."<machine-name>-<machine-id>"]
  expiresAt = "2027-09-07T18:00:00Z"
  ```

  See [SSH access](team-input.md#ssh-access) for expiry details.
- For SOPS decryption access, add the member to the
  `host-<machine-name>-<machine-id>` group and set their `agePublicKey`.

Update the team input:

```sh
nix flake update team
```

When `host-<machine-name>-<machine-id>` members are configured, secrets will be
automatically re-encrypted with their keys on shell entry. The bootstrap key in
`.data/machine-host-key/<machine-name>` is removed only after the configured
`IDR_USER` can decrypt the file with their own key.

---

At this stage, the configuration is not fully complete, since disk layout, network settings, and the server's IP have not been defined yet.
However, a test VM is already operational.

You can run the test VM with:

`idr`

(in terminal UI, navigate to `vm-<machine-name>` service and press `F7`)

Or start it in the background:

```sh
idr -D
idr process start vm-some-machine
```

Note that `idr` is a wrapper around process-compose.
Run `idr -h` to see the list of available commands.
See [local VM operation](local-vms.md) for SSH access, consoles, and QEMU settings.

### Hardware and network configuration

Generate `facter.json` on the target machine, then copy it into the machine's
directory. With Nix available on the target, run from the project directory:

```sh
ssh root@192.0.2.10 'nix run nixpkgs#nixos-facter -- -o /tmp/facter.json'
scp root@192.0.2.10:/tmp/facter.json nix/machine/some-machine/facter.json
git add nix/machine/some-machine/facter.json
```

The generated `configuration.nix` automatically loads the adjacent `facter.json`.

See [server presets](../nix/preset/README.md) for base settings and persistence.

Set the disk layout and network in `hardware-specific.nix`.

The default Disko layout in `hardware-specific.nix` uses two disks with LUKS-encrypted partitions
forming a ZFS mirror vdev, plus boot partitions and encrypted swap on each disk.

Replace the example disk IDs and sizes for your hardware. Use stable
`/dev/disk/by-id/` paths so disk selection does not depend on discovery order.

ZFS is recommended for snapshots, incremental backups, and per-dataset tuning.

See the [Disko examples](https://github.com/nix-community/disko/tree/master/example) for other layouts.

Configure networking through `systemd.network`. Match physical NICs by stable
hardware attributes, such as `matchConfig.MACAddress`.

The sample static configuration in `hardware-specific.nix` uses documentation addresses.
Replace its MAC, addresses, and routes if you choose static networking.

Then follow the
[installation guide](installation.md) to install the machine with `idr-anywhere`.

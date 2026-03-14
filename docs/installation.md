## Install a machine with idr-anywhere

`idr-anywhere` wraps `nixos-anywhere`, filling in options from the machine's configuration.

After [creating a machine configuration](mk-machine.md), use `idr-anywhere` to
install it over SSH. For later configuration updates, follow the
[deployment guide](deployment.md).

To install from images instead, use [idr-mk-images](mk-images.md) with `--type raw`
and write each image to its corresponding target disk.

### Prepare the configuration

Complete the [hardware and network setup](mk-machine.md#hardware-and-network-configuration) first.

The command takes a **deploy-rs node name**, normally the machine name, and uses
that node's SSH settings. Set the destination in the machine's
`flake-module.nix`. For example:

```nix
flake.deploy.nodes.some-machine.hostname = "192.0.2.10";
```

`hostname` accepts an IPv4 or IPv6 address, or a DNS name such as `machine.example.com`.

Boot the target into a Linux environment with root SSH access, such as a NixOS
installer or a provider's rescue system. Check that the configured disk paths
exist there. Your local development shell must be able to decrypt the machine's SOPS secrets.

Run the installation from the project development shell:

```sh
idr-anywhere some-machine
```

Use `--host`, `--user`, and `--port` to override the initial SSH connection. Use `-i`
for an identity file or `--ssh-option 'ProxyJump=jump.example.com'` for an SSH
option.

IDR supplies the configured disk-encryption keys and post-format files from SOPS.
Configure additional installation files through `idr.preset.base.preFormatFiles`
and `postFormatFiles`.

### Confirm disk operations

The command prints the target address and configured disks before requesting
confirmation. It first tries Disko's `format,mount` operation, which can reuse
matching layouts. If that fails, it falls back to a full wipe of the configured
disks. Existing data is therefore not guaranteed to survive.

| Confirmation | Required when |
|---|---|
| `WIPE_ALL_DISKS` | Always; authorizes wiping all disks in the target configuration. |
| `WIPE_LINUX` | Those disks are in use by the running non-NixOS Linux environment. |
| `WIPE_NIXOS` | Those disks are in use by the running NixOS environment. |

In a terminal, type each requested confirmation. To supply confirmations in
advance, use uppercase, comma-separated values with `--allow`. For example, when
the configured disks are not in use:

```sh
idr-anywhere some-machine --allow WIPE_ALL_DISKS -n
```

Missing confirmations cause an error when `-n` (`--non-interactive`) is given or
no terminal is available.

### Build and transfer options

Use `--build-on local`, `--build-on remote`, or `--build-on auto` to choose where Nix builds run.
The default is `auto`. For example:

```sh
idr-anywhere some-machine --build-on remote -L
```

- `--substitute-on-destination` lets the target obtain store paths from its binary caches.
- `--no-substitute-on-destination` disables substitution when copying store paths;
  those paths come from the controller.

`--no-substitute-on-destination` is the default when the deploy node has
`fastConnection = true`.

### First boot

After installation, the machine reboots. Unlock encrypted disks through the
initrd SSH server:

```sh
idr-unlock-disks some-machine
```

See [disk unlocking](unlock-disks.md) for options.

### Try installation in a local VM

First [start the local VM](local-vms.md) and wait until its image build and boot
have completed. Then clear its partition tables and start it again:

```sh
idr-wipe-local-vm vm-some-machine
idr process start vm-some-machine
```

The wipe command stops the VM before changing its disks. The next start boots the
installer ISO. Once `ssh vm-some-machine` connects to that installer, run:

```sh
idr-anywhere vm-some-machine
```

Automatic disk unlocking is enabled by default for local VMs.

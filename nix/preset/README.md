## Server presets and NixOS containers

Machines created by [`idr-mk-machine`](../../docs/mk-machine.md) already import
`inputs.idr.modules.nixos.preset`. It supplies the base server configuration,
persistent storage settings, and defaults for NixOS containers.

The examples below show optional settings to add to a machine's
`configuration.nix` or a role's NixOS configuration.

### Base preset

The generated configuration sets `idr.preset.base.id`, which enables the base
preset. It also sets `idr.preset.base.defaultSopsFile` to the machine's
`secrets.enc.json`.

The defaults include systemd-networkd with DHCP, nftables, key-based SSH access,
declarative users, Fail2ban, ZFS scrubbing, and Podman. Network and SSH access are
also configured in the initrd so disks can be unlocked remotely. Root SSH access
is controlled through the [team configuration](../../docs/team-input.md#ssh-access).

Use the regular NixOS options to change these defaults. For example, to disable
Podman:

```nix
virtualisation.podman.enable = false;
```

If you only need individual IDR service modules, set
`idr.preset.base.enable = false`.

For software difficult to package in Nix, use
`virtualisation.oci-containers.containers` to run an OCI image.
For workloads that require a separate kernel, a separately configured microVM
is another option.

### Persistent data

The generated disk layout resets the root filesystem on every boot, using
`idr.preset.impermanence.rootDataset = "p1/local/root"`. Files that must survive
a reboot are stored under `/persist` or on separately mounted persistent
filesystems.

Prefer separate ZFS datasets for application data so snapshots and filesystem
properties can be managed per workload.

The base preset enables `disko-zfs` for Disko ZFS pools. Deployments create
missing filesystem datasets and apply configured properties. Undeclared datasets
are retained, but undeclared properties on managed datasets may be reset.
ZVOLs are created by Disko during installation. Set `disko.zfs.enable = false`
to disable dataset management during deployments.

IDR uses [Impermanence](https://github.com/nix-community/impermanence) to make
files and directories stored under `/persist` available at their usual paths.
The preset already preserves `/etc/machine-id`, `/var/log`, `/var/lib/nixos`,
`/var/lib/systemd/coredump`, and `/var/lib/containers`. Managed SSH host keys are
stored directly under `/persist/etc/ssh`; see [key rotation](../../docs/key-rotation.md).

Add persistence entries for application data. For example, if a service runs as
`my-app` and stores data in `/var/lib/my-app`:

```nix
environment.persistence."/persist".directories = [
  {
    directory = "/var/lib/my-app";
    user = "my-app";
    group = "my-app";
    mode = "0700";
  }
];
```

The service must define the `my-app` user and group. To use a persistence
directory other than `/persist`, set `idr.preset.impermanence.persistDir` and
configure its filesystem too.

IDR's root-reset module requires ZFS. With another root filesystem, disable
`idr.preset.impermanence.enable` and configure persistence and root reset
separately, for example with tmpfs and `environment.persistence`.

### Additional local addresses

Use `idr.preset.loopback.addresses` to add addresses that services can bind to.
For example:

```nix
idr.preset.loopback.addresses = [
  "192.0.2.20/32"
  "2001:db8::20/128"
];
```

These addresses are assigned to `idr-lo`; configure routing and firewall access
separately.

### NixOS containers

Define containers through the regular [NixOS container
options](https://nixos.org/manual/nixos/stable/#ch-containers).

With the host's base preset enabled, IDR imports its modules into each container
and enables the base settings, excluding host-specific hardware and SSH setup.
Containers start automatically, share the host network by default, and use
`privateUsers = "no"`.

Treat these defaults as configuration separation, not as a security boundary.

For example, this adds a container serving a page at `http://127.0.0.1:8080` on
the host:

```nix
containers.example.config = {pkgs, ...}: {
  system.stateVersion = "26.05";
  services.nginx = {
    enable = true;
    virtualHosts.localhost = {
      listen = [
        {
          addr = "127.0.0.1";
          port = 8080;
        }
      ];
      root = pkgs.writeTextDir "index.html" "Hello from a container";
    };
  };
};
```

Prefer a separate ZFS dataset for application data and bind-mount it into the
container. For example, using the generated `p1` pool for a service that stores
data in `/var/lib/my-app`:

```nix
disko.devices.zpool.p1.datasets.my-app = {
  type = "zfs_fs";
  options.mountpoint = "legacy";
  mountpoint = "/p1/my-app";
};

containers.example.bindMounts."/var/lib/my-app" = {
  hostPath = "/p1/my-app";
  isReadOnly = false;
};
```

Set the data directory's ownership for the application's user and group.

Containers inherit the host's SOPS secrets and `idr.secrets-source` definitions.
The host's private SSH keys from `sops.age.sshKeyPaths` are mounted read-only into
each container to decrypt those secrets. See [runtime secrets](../secrets/README.md)
for configuration.

With `privateUsers = "no"` and `privateNetwork = false`, IDR reloads container
configuration changes without a restart when possible. Set
`idr.preset.base.reloadContainersWhenPossible = false` to use the upstream update
behavior.

## microVMs

Run NixOS guests with microvm.nix and Cloud Hypervisor. The host needs KVM support,
and host and guest must use the same CPU architecture. These examples use a guest
named `worker` and a host named `host`.

### Create a guest

Use the [machine creation guide](mk-machine.md) for personal keys and SSH/SOPS
access setup. Create the guest with the `microvm` template:

```sh
idr-mk-machine worker --template microvm
```

The template provides DHCP networking and a 64 GiB unencrypted Btrfs system disk.
Set `idr.microvmGuest.diskSizeMiB` in `config/microvm.nix` to change its initial
size. The root subvolume resets at each boot; `/nix`, `/persist` and `/boot`
survive. Declare application state as described in
[persistent data](../nix/preset/README.md#persistent-data).

In the guest configuration, authorize the host to decrypt its SOPS files and
connect through management SSH:

```nix
idr.preset.base.sopsRecipientMachines = [top.self.nixosConfigurations.host];
```

Re-enter the development shell to update the SOPS recipients before deploying
the host.

### Configure the host

This example uses an existing ZFS pool, `p1`, for the system disk. Add it to the
host's IDR machine configuration:

```nix
top: {...}: {
  idr.microvm.vms.worker = {
    machine = top.self.nixosConfigurations.worker;
    disks.system.pool = "p1";
  };
}
```

Deploy the host. IDR creates `p1/idr-microvm-worker`, installs the guest, and starts
it. Later deployments reuse the disk. Removing the VM from the configuration
leaves its disks in place. For image files, block devices, or additional disks,
see [Choose storage](#choose-storage).

### Connect and view logs

On the VM host, open a guest shell:

```sh
sudo idr-microvm-worker-ssh
```

This uses the private management connection and works without guest networking.
Guest boot output and hypervisor logs go to the journal by default:

```sh
sudo journalctl -b -fu microvm@idr-worker.service -o cat
```

Hypervisor `logLevel` defaults to `"warn"`; use `"info"`, `"debug"`, or `"trace"`
for more detail. For interactive recovery, see [Use the console](microvm-recovery.md#use-the-console).

### Updates and restarts

By default, host activation updates running guests to the configuration declared
by the host. Host reboots and VM restarts preserve manually deployed guest
versions. Stopped guests are skipped, with no update queued for their next start.
A failed automatic guest update also fails the host activation. Inspect update
logs on the host:

```sh
sudo journalctl -b -u idr-microvm-worker-deploy.service
```

To deploy just the guest from your project checkout, run on the VM host:

```sh
idr-microvm-worker-deploy
```

This builds as your user, then uses `sudo` for deployment. Use
`--flake /path/to/project` for another checkout; arguments after `--` go to
`nix build`.

Manual deployment leaves the host configuration unchanged. For independent guest
updates, disable automatic updates in the host configuration and deploy it:

```nix
idr.microvm.vms.worker.deployment.autoUpdate = false;
```

Otherwise, a later host activation can restore the host's declared version.
The SSH and manual deployment helpers remain available with automatic updates
disabled.

Kernel, bootloader, and hypervisor changes require a VM restart:

```sh
sudo systemctl restart microvm@idr-worker.service
```

Set `deployment.restartOnHypervisorChange = true` in the host's VM entry to
restart automatically when its hypervisor configuration changes. For rollback,
see [recovery](microvm-recovery.md#roll-back-the-guest).

### Choose storage

Host `disks` entries correspond to guest Disko disks by name. Each is exposed as
`/dev/disk/by-id/virtio-idr-<name>`; use that path in the guest's
`disko.devices.disk.<name>.device`.

Disks can mix zvols, image files, and block devices:

```nix
idr.microvm.vms.worker.disks = {
  system.pool = "p1";
  data = {
    path = "/var/lib/microvm-disks/worker-data.qcow2";
    format = "qcow2";
  };
  archive.path = "/dev/disk/by-partlabel/worker-archive";
};
```

`path` is a path on the host. Format defaults to `"raw"`; use `"qcow2"` for a
standalone QCOW2 image. Missing image files are created automatically.

Managed zvols default to `p1/idr-microvm-worker` for `system` and
`p1/idr-microvm-worker-<name>` for other disks. Set `pool` or `dataset` to change
this; any parent dataset must already exist.

IDR initializes supplied raw storage only when it finds no partition table or
recognized filesystem or RAID signature. A QCOW2 container is initialized only
when its virtual contents are all zero.

Existing files and devices must be readable and writable by `microvm`. For a
host partition created by Disko, use a udev rule:

```nix
services.udev.extraRules = ''
  SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_PART_ENTRY_NAME}=="worker-archive", OWNER="microvm", GROUP="root", MODE="0600"
'';
```

The guest's partition table is written *inside* the selected host partition.

Provisioning defaults to `"zvol"` for the generated ZFS path, `"block"` for other
`/dev/…` paths, and `"image"` otherwise. Set a disk's `provisioning = "none"` to
attach it without initialization.

For a zvol managed elsewhere, set its `path` and `provisioning = "block"`.

A disk's `sizeMiB` overrides the initial image or managed-zvol size; by default it
follows that disk's Disko image size. Existing disks keep their capacity.

To replace a disk with a fresh installation, see
[Recreate a disk](microvm-recovery.md#recreate-a-disk).

### Networking and SSH

TAP networking is enabled by default. The host serves DHCP with fixed guest
addresses and provides outbound connectivity. `idr-mk-machine` assigns the first
available IPv4 address from the project's range, `10.1.0.0/16` by default.
Set project defaults with `idr.microvm.network.ipv4Subnet` and
`idr.microvm.network.ipv6Prefix` in a project `flake-module.nix` before creating
guests. Existing IPv4 assignments are kept in their guest configurations.
IPv6 addresses combine the ULA prefix (default `fd54:0fb7:359f`), host ID and
guest ID.

The host filters guest traffic to its assigned MAC and IP addresses. Guests can
use host DHCP and DNS, but otherwise cannot initiate connections to the host or
other guests. The host can initiate SSH connections to guests.

Firewall settings belong in the host's NixOS configuration. Set
`idr.microvm.network.firewall.allowHostSSH = false` to close host-to-guest SSH.
Add exceptions with `extraInputRules`, `extraForwardRules`, or `extraOutputRules`
under the same firewall option, or set `enable = false` to manage those rules
yourself.

For missing addresses or failed connections, see
[network troubleshooting](microvm-recovery.md#check-guest-networking).

On the VM host, connect over SSH:

```sh
ssh root@worker
```

To deploy through the guest's network connection, run separately from the
project development shell on the host:

```sh
deploy -s .#worker
```

From another machine, use the VM host as a jump host:

```sh
ssh -J root@host root@worker
```

To deploy from that machine through the same jump host:

```sh
deploy -s .#worker --ssh-opts="-J root@host"
```

### Shared folders

Configure a shared folder on the host:

```nix
idr.microvm.vms.worker.shares.work.source = "/srv/work";
```

In the guest's configuration, add the corresponding mount:

```nix
fileSystems."/work" = { device = "work"; fsType = "virtiofs"; };
```

### Memory

Memory ballooning is enabled by default. RAM is allocated on demand up to the
host's usable RAM; set `memory.maximumMiB` for a lower limit. Hypeman reclaims
memory under host pressure, and earlyoom handles process killing inside guests.
Configure the shared policy under `idr.microvm.memory`.

### PCI passthrough

PCI passthrough is disabled by default. For a GPU and its companion function:

```nix
idr.microvm.vms.worker.pci = {
  enable = true;
  devices = ["0000:0d:00.0"];
  bindOnlyDevices = ["0000:0d:00.1"];
};
```

Enable IOMMU support in the host firmware and reboot after deploying the host
kernel changes. Enable the guest's device driver; for headless NVIDIA use, set
`idr.microvmGuest.nvidia.enable = true`.

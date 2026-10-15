## MicroVM recovery

These examples use a guest named `worker`. Run the commands on its VM host.
See the [MicroVM guide](microvm.md) for setup and routine operations.

### Connect without guest networking

The host's management SSH command works even when the guest's IP network or
ordinary SSH service is unavailable:

```sh
sudo idr-microvm-worker-ssh
```

The guest must have booted far enough to start management SSH. For earlier boot
failures, check the [guest boot logs](microvm.md#connect-and-view-logs).

### Use the console

Enable the interactive serial console in the host's VM configuration:

```nix
idr.microvm.vms.worker.console = "socket";
```

Stop the VM before deploying this change:

```sh
sudo systemctl stop microvm@idr-worker.service
```

Deploy the host configuration, then start the VM:

```sh
sudo systemctl start microvm@idr-worker.service
```

Connect to the console socket:

```sh
sudo nix run nixpkgs#socat -- \
  STDIO,raw,echo=0,escape=0x1d \
  UNIX-CONNECT:/run/idr-microvm-worker/private/console.sock
```

This console includes firmware and bootloader access. Press **Ctrl+]** to disconnect.

### Roll back the guest

For a manual rollback, first set this in the host configuration and deploy it:

```nix
idr.microvm.vms.worker.deployment.autoUpdate = false;
```

Then roll back the guest:

```sh
sudo idr-microvm-worker-ssh 'nixos-rebuild switch --rollback --no-reexec'
```

Keep automatic updates disabled until the declared guest configuration is fixed,
so a later host activation does not reapply it. Rollback restores the system
generation; application data and copied extra files are not reverted. Reboot the
guest if the rollback changes its kernel.

### Recreate a disk

Choose the disk from `idr.microvm.vms.worker.disks`. **Recreating it erases all
data on that disk.** Other disks and shared host directories are kept.

Stop the VM and its installation service first:

```sh
sudo systemctl stop microvm@idr-worker.service idr-microvm-worker-install.service
```

For an image file, remove its `path`. For the `data` disk in the
[storage example](microvm.md#choose-storage):

```sh
sudo rm -- /var/lib/microvm-disks/worker-data.qcow2
```

For an **IDR-managed ZFS volume**, remove its configured `disks.<name>.dataset`.
The default system disk is `p1/idr-microvm-worker`:

```sh
sudo zfs list -o name,volsize p1/idr-microvm-worker
sudo zfs destroy p1/idr-microvm-worker
```

For each managed zvol being recreated, check for a staging volume named
`<dataset>-installing`. For the default system disk:

```sh
sudo zfs list p1/idr-microvm-worker-installing
```

If it exists, remove that exact volume too with
`sudo zfs destroy p1/idr-microvm-worker-installing`. Otherwise the installer can
resume it instead of creating a fresh disk.

For a supplied physical disk, host partition, or externally managed zvol,
reset the device explicitly before reinstalling. See the
[storage initialization rules](microvm.md#choose-storage).

Deploy the desired host configuration from the project development shell. Then,
on the VM host, start the guest and follow installation:

```sh
sudo systemctl start --no-block microvm@idr-worker.service
sudo journalctl -f -u idr-microvm-worker-install.service -u microvm@idr-worker.service
```

### Check guest networking

Inspect guest addresses, routes, and the host's DHCP logs:

```sh
sudo idr-microvm-worker-ssh 'ip -brief address; ip route; ip -6 route'
sudo journalctl -b -u dnsmasq --no-pager -n 80
```

Host-to-guest ping is blocked by default. Allow it with
`idr.microvm.network.firewall.extraOutputRules` in the host configuration.

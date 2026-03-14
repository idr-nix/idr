## Run local QEMU VMs

The local VM workflow currently supports `x86_64-linux` hosts and guests.

Test configuration and deployment changes in a local VM before applying them to
a server. The VM boots generated disk images, exercising the disk layout and
bootloader. It uses the same NixOS configuration, with local networking and SSH
access activated at runtime.

From the project development shell, start Process Compose and the machine's VM:

```sh
idr -D
idr process start vm-some-machine
```

The first start builds missing disk images. Later starts reuse them; apply
system configuration changes through [deployment](deployment.md#local-vms).

Follow the VM's output, including its serial console:

```sh
idr process logs -f vm-some-machine
```

Use `idr attach` to open the Process Compose terminal UI, or
`idr process stop vm-some-machine` to stop the VM. `idr down` stops all processes
managed by the project.

See [local networking and workspaces](local-networking.md) for host setup and
running separate development environments.

### SSH and disk unlocking

Once Process Compose reports the VM ready:

```sh
ssh vm-some-machine
```

The development shell's SSH wrapper connects as root using a local key encrypted
with the machine's SOPS policy. Your shell must be able to decrypt it.

Encrypted disks unlock automatically, including after guest reboots. To disable
this for testing, follow [manual unlocking](unlock-disks.md#local-vms).

### Consoles

Connect to the serial console using the machine name:

```sh
idr-serial some-machine
```

Log in to the installed system as `root`, using `root_password` from
`nix/machine/some-machine/secrets.enc.json`.

Press **Ctrl-Z** to disconnect. Set `IDR_SERIAL_ESCAPE=ctrl-]` to use **Ctrl-]**.

On Linux, enable VNC as shown below, then open its display with:

```sh
idr-vnc some-machine
```

### QEMU settings

Add runner settings to the existing `config` block in `configuration.nix`:

```nix
idr.meta.preset.base.qemu = {
  memorySize = 8192;
  vnc.enable = true;
  options = ["-smp" "4"];
};
```

The VM uses 4096 MiB of RAM by default. Graphics and VNC are disabled by default;
`graphics = true` opens QEMU's graphical window.

After changing runner settings, re-enter the development shell, restart
Process Compose, and start the VM again.

With Process Compose stopped, pass additional QEMU options for its next run:

```sh
env IDR_QEMU_EXTRA_OPTIONS_JSON='["-m","8192","-smp","4"]' idr -D
```

### Recreate disks or boot the installer

To discard the VM's disk contents and rebuild installed images:

```sh
idr process stop vm-some-machine
nix run .#nixosConfigurations.some-machine.config.system.build.idrQemu -- --force
```

This runs the rebuilt VM in the current terminal. The runner also accepts
`--build-memory 8192` to set the image-build VM's RAM in MiB (default: 16384).

`idr-wipe-local-vm vm-some-machine` stops the VM and clears partition tables
while leaving partition contents in place. Its next start boots the
installer ISO. Follow the [local installation workflow](installation.md#try-installation-in-a-local-vm)
to install through `idr-anywhere`.

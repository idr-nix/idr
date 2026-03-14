## Create disk images

`idr-mk-images` builds disk images with the machine's system already installed.
It uses the configured Disko layout and installation files from SOPS. Run it from
the project development shell with access to decrypt those secrets:

```sh
mkdir .data/images
idr-mk-images some-machine .data/images
```

The command takes a machine name from `nixosConfigurations` and an optional
destination directory. The directory must already exist; omitting it writes to
the current directory.

Each disk produces `<imageName>.<format>`, such as `disk-1.qcow2` and
`disk-2.qcow2`. Disko's `imageName` defaults to the disk's configuration name;
`imageSize` sets its virtual size. Running the command again replaces matching
output images.

### Formats and build memory

Select the format with `--type` (`-t`):

| Format | Output |
|---|---|
| `qcow2` (default) | QCOW2 with Zstandard compression. |
| `raw` | Raw disk images for writing directly to disks. |
| `vmdk` | Compressed, stream-optimized VMDK. |

Other `qemu-img` output formats can also be selected.

`--build-memory` (`-m`) sets the Disko build VM's memory in MiB; the default is
`16384`. For example:

```sh
idr-mk-images some-machine .data/images --type raw --build-memory 8192
```

Write each raw image to its corresponding target disk, replacing its contents.
The target must be at least as large as the image's virtual size. After booting
the installed system, [unlock its encrypted disks](unlock-disks.md).

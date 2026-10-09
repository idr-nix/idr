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
`imageSize` sets its virtual size. Running the command again reuses current
images where possible and replaces matching outputs when rebuilding or converting.

### Formats and build memory

Select the format with `--type` (`-t`):

| Format | Output |
|---|---|
| `qcow2` (default) | Uncompressed, sparse QCOW2 disk images. |
| `raw` | Raw disk images for writing directly to disks. |
| `vmdk` | Stream-optimized VMDK disk images. |

`--build-memory` (`-m`) sets the Disko build VM's memory in MiB; the default is
`16384`. For example:

```sh
idr-mk-images some-machine .data/images --type raw --build-memory 8192
```

Write each raw image to its corresponding target disk, replacing its contents.
The target must be at least as large as the image's virtual size. After booting
the installed system, [unlock its encrypted disks](unlock-disks.md).

Pass additional `qemu-img convert` options directly, for example to compress QCOW2
images with Zstandard:

```sh
idr-mk-images some-machine .data/images -c -o compression_type=zstd
```

Additional options reconvert current images even when the destination and format
match. They do not force a fresh installation build. IDR's own flags retain their
meanings.

### Reuse installed images

The command reuses up-to-date images from the destination or the machine's local
VM started with `idr -D`. It converts them to the requested format and preserves
the source images. Stop the VM before exporting its disks. Exported images
include changes made while the VM ran.

Select another source directory with `--source`:

```sh
idr-mk-images some-machine .data/export --source .data/images --type vmdk
```

When copying images, include their hidden `.idr-mk-images-*.json` files so they
can be reused. Missing, outdated, or damaged image sets are rebuilt automatically.
Reusing current images does not require decrypting secrets.

Use `--force` (`-f`) to build fresh installed images and replace matching outputs:

```sh
idr-mk-images some-machine .data/images --force
```

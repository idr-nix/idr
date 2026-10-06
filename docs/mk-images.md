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
| `qcow2` (default) | QCOW2 with Zstandard compression. |
| `raw` | Raw disk images for writing directly to disks. |
| `vmdk` | Compressed, stream-optimized VMDK. |

Other `qemu-img` output formats can also be selected.

`--build-memory` (`-m`) sets the Disko build VM's memory in MiB; the default is
`16384`. On Linux, the builder's QEMU memory is allocated as the guest touches it,
up to this fixed limit; it does not grow automatically, and the entire amount is
not preallocated. All disks are installed
in one VM because the layout can include pools or volumes spanning disks.
For example:

```sh
idr-mk-images some-machine .data/images --type raw --build-memory 8192
```

After installation, images are converted concurrently when resources allow.
The automatic limit is two conversions, bounded by available CPUs and one GiB
of available host memory per conversion. Set `--jobs` (`-j`) to override it;
`--jobs 1` converts sequentially and can help on slower storage.

Write each raw image to its corresponding target disk, replacing its contents.
The target must be at least as large as the image's virtual size. After booting
the installed system, [unlock its encrypted disks](unlock-disks.md).

### Reuse installed images

The command first looks for a current, complete image set in the destination,
then in the machine's local VM directory used by `idr -D`:
`$PRJ_DATA_DIR/<host-id>/<machine>/qemu`. It converts those images to the requested
format without moving or deleting the source images. Stop the local VM before
exporting its disks. Reused VM images include changes made while that VM ran.

Select another source directory with `--source`:

```sh
idr-mk-images some-machine .data/export --source .data/images --type vmdk
```

Keep the hidden `.idr-mk-images-<machine>-<format>.json` receipt with its images
when copying a set to another source directory. The receipt records the Disko
builder, disk layout and encrypted installation inputs. Reuse requires a matching
receipt and valid images of the expected sizes. Missing, stale or damaged sets
are rebuilt; old images without receipts are rebuilt once. Reuse requires no
secret decryption. Changes to encrypted installation files invalidate the receipt,
even when the Nix image builder itself is unchanged.

Use `--force` (`-f`) to build fresh installed images and replace matching outputs:

```sh
idr-mk-images some-machine .data/images --force
```

Other formats already in either directory remain in place. Receipts describe
the installation inputs, not a pristine filesystem: they do not undo guest writes
or deployment changes. Normal local VM restarts keep existing disks regardless
of configuration changes; use the VM runner's `--force` to recreate them.

## Local networking and workspaces

Local VMs use IPv6 addresses formed from the network prefix, workspace ID, and
machine ID. With the default prefix, workspace `42b08923`, and machine ID
`1e6f6e96b47c`, the address is:

```text
fd3e:aacc:e60e:42b0:8923:1e6f:6e96:b47c
```

The generated `vm-` SSH aliases select these addresses. The initrd and default
installer ISO also configure this network.

### Host networking

On Linux, VMs share the `idr0` bridge and its `/48` network. The host's address is
`fd3e:aacc:e60e::1/48` by default. This provides host/VM and VM/VM connectivity;
external routing must be configured separately.

When the bridge and route are ready, the runner looks for `qemu-bridge-helper`
on `PATH` and in common system locations. Set `IDR_QEMU_BRIDGE_HELPER` before
starting Process Compose to select another helper. Its bridge ACL must allow
`idr0`.

If the bridge or route is missing, or no helper is found, the runner uses `sudo`
to set up the network. It prompts through rofi by default; `SUDO_ASKPASS` selects
another password prompt. This fallback does not write persistent host
configuration. For a NixOS host, use the [QEMU host module](../nix/qemu-host/README.md)
to configure the bridge and helper.

### Workspace IDs

`IDR_WORKSPACE_ID` accepts eight hexadecimal digits. It defaults to `00000000`
in the main checkout. Linked Git worktrees get their own predictable IDs.

For an explicit ID, set it before entering the development shell so the SSH
configuration and VM runner use the same value:

```sh
env IDR_WORKSPACE_ID=42b08923 nix develop
```

From outside the existing development shell, create and enter a separate
worktree:

```sh
git worktree add -b local-feature ../project-local
cd ../project-local
nix develop
```

Then [start its VMs](local-vms.md). Each worktree has its own `.data` directory
by default. Changing only the workspace ID in one directory keeps the same VM
disks and Process Compose socket.

### Project data on multiple hosts

`PRJ_DATA_DIR` normally defaults to `$PRJ_ROOT/.data`. Set an override before
entering the development shell or loading direnv; use a separate data directory
for each worktree.

VM disks, VM SSH keys, sockets, and caches are separated by host under
`PRJ_DATA_DIR`. The host ID comes from `/etc/machine-id`, falling back to the
hostname when the file is absent or empty. This lets multiple hosts with
distinct IDs use the same mounted project directory.

### Network prefix

Set `idr.qemu.networkPrefix` in each machine's NixOS configuration to change the
default `fd3e:aacc:e60e` prefix. Use three lowercase hexadecimal groups in the
form `fdxx:xxxx:xxxx`, without a prefix length. Use the same prefix for all VMs
sharing the bridge and for the NixOS host module.

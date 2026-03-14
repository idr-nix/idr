## QEMU host bridge

Import `inputs.idr.modules.nixos.qemu-host` into the development host's NixOS
configuration, then enable the bridge:

```nix
idr.qemu-host.enable = true;
```

This configures the `idr0` bridge through systemd-networkd, assigns
`fd3e:aacc:e60e::1/48`, and installs a privileged QEMU bridge helper with an ACL
allowing `idr0`. Apply the host configuration before starting local VMs.

If using a custom `idr.qemu.networkPrefix`, set the same value on the host and
its VMs. See [local networking and workspaces](../../docs/local-networking.md).

If VMs are unreachable, inspect the bridge and its attached TAP interfaces:

```sh
ip -6 address show dev idr0
ip -6 route show dev idr0
bridge link
```

Ensure broad host DHCP or network-manager rules do not detach the QEMU TAP
interfaces from `idr0`.

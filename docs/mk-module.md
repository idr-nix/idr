## idr-mk-module

Create a reusable NixOS module with:

```sh
idr-mk-module some-module
```

This creates two files in `nix/some-module/`:

- `flake-module.nix` exports the NixOS module as `flake.modules.nixos.some-module`.
- `nixos-module.nix` declares named instances at `idr.some-module` and contains the module's configuration.

Machines created by [`idr-mk-machine`](mk-machine.md) automatically import exported
project NixOS modules.

The template supports multiple named instances on the same machine. No instances
are configured by default. Declaring an instance enables it unless its `enable`
option is false.

Declare instances from a role or machine configuration:

```nix
idr.some-module = {
  first = {};
  second = {};
  paused.enable = false;
};
```

Add instance options alongside `enable` in the generated submodule. Keep
[ports](ports.md), data directories, and other settings configurable so instances can coexist.
Keep environment-specific domains, secrets, and settings out of reusable modules.
Expose options for them and supply their values from roles.

Add configuration inside the generated `lib.mkIf` block. The `cfgs` variable
contains only enabled instances; use `lib.concatMapAttrs (name: cfg: { ... }) cfgs`
to create settings for each one. The template includes a commented example of
services named after their instances.

When a service supports reloading, use it to apply configuration changes without
restarting the service.

Consult the upstream NixOS module source when its option documentation is unclear.

If an upstream service module supports only one instance, run each instance in a
separate [NixOS container](../nix/preset/README.md#nixos-containers). Configure
[persistent storage](../nix/preset/README.md#persistent-data) for service data that
must survive reboots.

### Service users

Prefer `DynamicUser = true;` in `systemd.services.<name>.serviceConfig`.
For persistent data, set `StateDirectory = "<name>";` and mount or bind-mount
the data's ZFS dataset at `/var/lib/private/<name>`.

If the service cannot use `DynamicUser`, define its user and group with explicit
`uid` and `gid`, and select them with `User` and `Group` in `serviceConfig`.

Avoid automatically allocated IDs for accounts that own persistent service data.
IDR preserves `/var/lib/nixos`, keeping allocated IDs stable on the same machine.
Restoring or moving service data to another machine still requires reconciling
file ownership with that machine's account IDs.

### UID/GID selection

Reuse fixed IDs already supplied by NixOS. For additional IDs, use these project
conventions:

| Purpose | Range |
|---|---|
| LDAP users and groups | `5000–9999` |
| Custom static service IDs | `10000–29999` |

Keep custom service allocations together in the project's
`nix/ids/nixos-module.nix`, using `ids.uids` and `ids.gids`. Reference them from
`users.users.<name>.uid` and `users.groups.<name>.gid`.

Store LDAP IDs as `uidNumber` and `gidNumber` in the [team configuration](team-input.md).

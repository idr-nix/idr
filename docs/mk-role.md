## idr-mk-role

Create a role with:

```sh
idr-mk-role some-role
```

This creates the following files in `nix/role/some-role/`:

1. `meta.json` - the role ID
2. `flake-module.nix` - registers the role's NixOS module
3. `nixos-module.nix` - the role's options and configuration

It also adds the role importer at `nix/role/flake-module.nix`.

A useful naming pattern is `<environment>-<service>`, such as `stg-backend` and
`live-backend` for roles that configure the same reusable backend module.

Add the role's settings inside the generated `lib.mkIf` block. Enable it in a
machine configuration using the ID from `meta.json`:

```nix
idr.roles."some-role-<id>".enable = true;
```

### Optional secrets

If the role needs secrets, add team members who need decryption access to the group
`role-some-role-<id>`, using the ID from `meta.json`, and configure their
`agePublicKey` in the [team input](team-input.md). Machines in the same repository
that enable the role and members of those machines' `host-<machine-name>-<machine-id>`
groups are also included as encryption recipients.

Update the team input:

```sh
nix flake update team
```

Then enter the development shell again and create the secrets file:

```sh
sops nix/role/some-role/secrets.enc.json
```

See [runtime secrets](../nix/secrets/README.md) to expose values to services.

### Roles from another repository

Add the role repository as a flake input, for example `application`. Append
`builtins.attrValues top.inputs.application.modules.nixos` to the machine's
existing `imports`, then enable the role using its name and ID as above.

If the role uses secrets, add the machine to the team used by the role repository:

```toml
["<machine-name>-<machine-id>"]
system = true
agePublicKey = "<machine-age-public-key>"
groups = ["role-some-role-<id>"]
```

Use `ssh_host_ed25519_key_age_pub_unencrypted` from the machine's `secrets.enc.json`
as `agePublicKey`. Update this entry when the machine's SSH host key rotates.

After publishing the team change, run `nix flake update team` in the role
repository. Re-enter its development shell with an identity that can decrypt the
existing role secrets to update their recipients. Commit and push the changes.

Then update the role repository input in the machine repository:

```sh
nix flake update application
```

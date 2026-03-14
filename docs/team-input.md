## Team input

The `team` flake input keeps team members and access settings in one place.

The generated `flake.nix` starts with an empty team input:

```nix
inputs = {
  # ...
  idr = {
    # ...
    inputs = {
      # ...
      team.follows = "team";
    };
  };
  team = {
    url = "file+file:///dev/null";
    flake = false;
  };
};
```

Create a repository containing `team.toml`. For example:

```toml
[John]
firstName = "John"
lastName = "Doe"
uidNumber = 5000
gidNumber = 5000
mail = "john@gmail.com"
sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEjuIF2uXOUQyThLB6O5jmHCcz11uokg9XCAot+XHzM3"
agePublicKey = "age1qe5lxzzeppw5k79vxn3872272sgy224g2nzqlzy3uljs84say3yqgvd0sw"
hashedPassword = "$6$shbkxskXPgRS7lji$pHjw2sQLGTWvOPcfZLsr68as4L620Il0uD/Ku3nLnxT7IMYq9C5.Cu1UDXhLwFdgz1z9rX9OeXpSjo7dvt/ix0"
groups = [
  "concourse_users",
]
```

Then update `flake.nix` to use that repository:

```nix
inputs = {
  # ...
  team = {
    url = "git+ssh://git@github.com/myorg/team";
    flake = false;
  };
};
```

Modules can read the parsed contents through `top.idr-lib.team`, including any
additional fields you add. IDR uses it for SSH access, secret encryption
recipients, and the [LDAP module](../nix/ldap/README.md).

### System members

Set `system = true` for machine identities to exclude them from LDAP. For example,
register an [automatic disk-unlock server](../nix/disk-unlock/README.md) using its
machine name and ID:

```toml
["unlock-server-1e6f6e96b47c"]
system = true
groups = ["unlock-server"]
hostname = "192.0.2.40"
port = 64998
sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPsWVu+D+kh5+H3bFWqcqF8M5QPB9eB9nny5QJn29a+1"
agePublicKey = "age1ppz7rsx6djul63rm70t65whuzgmxhx805ptncy7s343drsneh5as0wkvfu"
```

Use the server's SSH host public key and its corresponding age public key.
`hostname` accepts an IP address or hostname; `port` is the notification port and
defaults to `64998`.

The `unlock-server` group grants access to machine `disk-key.enc.json` files.
It does not grant access to other machine secrets or role secrets.

Members of the `backup-server` group are authorized for read-only ZFS replication
through the [backup module](../nix/backup/README.md).

### SSH access

Grant root SSH access to a machine through a member's `sshAccess` table. Each entry uses
`<networking.hostName>-<idr.preset.base.id>` as its key and authorizes that member's
`sshPublicKey`:

```toml
[John.sshAccess."example-x86_64-linux-1e6f6e96b47c"]
expiresAt = "2027-09-07T18:00:00Z"

[John.sshAccess."other-machine-4c5979a1c350"]
```

Each grant table accepts only the optional `expiresAt` field. Omit it for permanent
access. When present, it must be a quoted timestamp in exactly
`YYYY-MM-DDTHH:MM:SSZ` format with a valid calendar date and UTC time after
the Unix epoch (`1970-01-01T00:00:00Z`).

The member's `sshPublicKey` must contain a single bare public key, with an optional
comment but no key options or line breaks.

OpenSSH enforces expiry at authentication without another deployment. Existing SSH
connections, including multiplexed connections, remain usable.

Update the team input:

```bash
nix flake update team
```

Then deploy the updated machine configuration.

## LDAP

The LDAP module publishes team members in a directory served by OpenLDAP.

The following example uses three [runtime secrets](../secrets/README.md):

- `ldap-cert` - the PEM certificate chain
- `ldap-cert-key` - the PEM private key
- `ldap-admin-password` - an OpenLDAP password hash, such as one produced by
  `slappasswd`

Add the instance to a role's NixOS configuration. For example:

```nix
idr.ldap.main = {
  secondLevelDomain = "example";
  topLevelDomain = "com";
  cert = config.idr.secrets.ldap-cert;
  certKey = config.idr.secrets.ldap-cert-key;
  rootPassword = config.idr.secrets.ldap-admin-password;
  allowedIPs = ["192.0.2.10" "2001:db8::/64"];
};
```

This instance runs in the `ldap-main` NixOS container and listens on LDAPS port
636. Set `port` to use another port; instances on the same machine need distinct
ports. Use `allowedIPs` to allow client addresses or CIDR ranges through the host
firewall. Both IPv4 and IPv6 are supported.

The default domain for this example is `ldap.example.com`. It resolves to
loopback on the server for local access. Configure external DNS and certificates
separately.

### Directory users

The example creates the directory suffix `dc=example,dc=com` with administrator
DN `cn=admin,dc=example,dc=com`. Users appear under `ou=users`, and groups under
`ou=groups`.

Users come from the [team input](../../docs/team-input.md), excluding members with
`system = true`. Each needs `firstName`, `lastName`, and `mail`. By default, the
team member name becomes its LDAP `uid`.

Optional fields are `uid`, `uidNumber`, `gidNumber`, `hashedPassword`,
`sshPublicKey`, `agePublicKey`, and `groups`. Bare crypt password hashes receive
the `{CRYPT}` prefix; existing LDAP hash prefixes are preserved.

Choose `uidNumber` and `gidNumber` using the
[UID/GID conventions](../../docs/mk-module.md#uidgid-selection).

To override a field for a team member, set it under `users`:

```nix
idr.ldap.main.users.some-user.mail = "some-user@example.com";
```

You can also define additional users there with the same fields. To replace the
complete set of users, use `lib.mkForce { ... }`.

Deploy changes to update the directory; its contents are read-only through LDAP.
Updates to the referenced secrets restart the container.

### Client authentication

For a user bind, use `uid=<uid>,ou=users,dc=example,dc=com` with that user's
password. Anonymous binds are disabled. Ordinary users can read their own
entries; the directory administrator can read the full directory.

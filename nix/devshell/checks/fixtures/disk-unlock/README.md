These SSH identities and the disk passphrase are deliberately public fixtures.
They protect only synthetic data on isolated NixOS test disks. Never reuse them
on a real machine.

`server-key` is both the unlock server's SSH host identity and the age identity
that decrypts `disk-key.enc.json`. `client-initrd-key` pins the client's initrd
SSH server. The disk passphrase is `public-idr-disk-unlock-test-passphrase`.

The `stale-*` files model an unlock server that still has the previous target
host pin and disk key after a target key rotation. The refresh test applies the
current target profile to that server and checks that the next initrd retry
unlocks the disk.

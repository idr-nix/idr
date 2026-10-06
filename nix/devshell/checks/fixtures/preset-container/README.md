The SSH identity in this directory is deliberately public and is only for tests.
The encrypted files contain synthetic application tokens. Never reuse this key.

The container tests install the key as a test host's SOPS SSH identity, so they
exercise the preset's read-only key mounts and inherited secret declarations.

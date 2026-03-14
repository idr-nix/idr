## Deploy configuration changes

Use `deploy` from [deploy-rs](https://github.com/serokell/deploy-rs) to update an
[installed machine](installation.md).
IDR creates a deploy node for each machine, using root as the default SSH user:

```sh
deploy -s .#some-machine -- -L
```

`-s` skips the preliminary flake checks; omit it when you want to run them.
`-- -L` enables Nix build logs.

Builds run locally by default; add `--remote-build` to build on the destination.
Use `--dry-activate` to preview activation, `--test` to activate without updating
the bootloader, or `--boot` to update the boot configuration without switching
the running system.

### Copy extra files

When `idr.preset.base.postFormatFiles` changes, copy those files before deploying:

```sh
idr-copy-extra-files some-machine
deploy -s .#some-machine -- -L
```

This includes new SSH host keys. Unchanged file contents are skipped.

Disk keys are supplied through SOPS during activation.
See [key rotation](key-rotation.md) for the rotation workflow and recovery.

The copy command accepts `--host`, `--user`, and `--port` for connection overrides.

### Local VMs

After [starting the local VM](local-vms.md), deploy to its generated `vm-` node:

```sh
deploy -s .#vm-some-machine -- -L
```

### Connection settings and timeouts

Configure the destination in the machine's `flake-module.nix`, as described in
the [installation guide](installation.md#prepare-the-configuration). For example,
set a custom SSH port and allow ten minutes for activation:

```nix
flake.deploy.nodes.some-machine = {
  sshOpts = ["-p" "2222"];
  activationTimeout = 600;
};
```

`activationTimeout` controls how long deploy-rs waits for activation after the
build. Generated VM nodes already use 600 seconds. `confirmTimeout` controls the
confirmation window after activation.

### Rollback

Deploy-rs enables two rollback mechanisms by default:

- `autoRollback` attempts to reactivate the preceding profile if activation fails.
- `magicRollback` attempts to roll back if activation is not confirmed over SSH.

Deploy-rs confirms activation automatically by reconnecting over SSH.

For a deliberate rollback from a working deployed generation, connect using the
machine's SSH address and options. For example:

```sh
ssh -p 2222 root@192.0.2.10 'nixos-rebuild switch --rollback --no-reexec'
```

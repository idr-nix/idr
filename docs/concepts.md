## Flake modules

Flake modules are the main extension mechanism of IDR. They use flake-parts to
compose project configuration without keeping everything in `flake.nix`.

Prefer a module under `nix/<feature>/` for feature-specific flake settings.
Keep input declarations in `flake.nix`.

The generated project imports `nix/*/flake-module.nix` automatically. The machine
and role importers do the same for their subdirectories. Flake modules can also be
imported explicitly through flake-parts.

The [machine](mk-machine.md), [role](mk-role.md), and [module](mk-module.md)
templates follow this structure.

## Roles

Roles are NixOS modules that group configuration for an environment. For example,
a role can configure a service's domain and secrets for production or staging.
Machine-specific settings belong in the machine configuration.

Use distinct service names and make ports and data directories configurable, with
defaults where they make sense. Roles from different projects may share a machine.
Keep disk and filesystem choices in the machine configuration; when a data path
depends on that layout, expose it as an option without a default.

Roles are a place to experiment. It is fine to start with similar configuration
duplicated across environments and extract a reusable module as the common parts
become clear. Leave environment-specific settings in the roles.

## Machines

A project can define several machines. Each machine configuration brings together:

1. Network settings.
2. Disk layout, configured through Disko.
3. The [base preset and persistence settings](../nix/preset/README.md).
4. Enabled roles and their options.

Keeping machine-specific settings here makes roles easier to move between
machines. The machine's `configuration.nix` should read as an overview of its
enabled roles and modules.

Regular NixOS modules can also be used directly. A role is useful when several
settings need to be grouped and reused together.

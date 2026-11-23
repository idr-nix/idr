## Packages

Declare a package in a flake module, for example a role's `flake-module.nix`:

```nix
_: {
  perSystem = {pkgs, ...}: {
    idr.packages.my-tool.package = pkgs.callPackage ./my-tool/package.nix {};
  };
}
```

`package.nix` is a package in the nixpkgs format, with its version and hashes
written in the file. The package is exported as `packages.<system>.my-tool` on
the systems in its `meta.platforms`.

### Update

From the development shell, run:

```sh
idr-update-packages          # all packages
idr-update-packages my-tool  # only the named ones
```

The command runs each package's update script once, from the project root, as
declared for the development shell's system, then builds the package if that
system supports it. Packages update in parallel, one per CPU thread; `--threads`
(`-t`) sets another limit. Failed packages are reported at the end, after the
others are updated. Changes stay in the working tree for review.

The default update script runs `nix-update --flake <name>`, which updates the
version and the hashes for the current system. When sources differ between
systems, set `update` to a script that updates every system's hash. For
example, expose each system's source as `src-<system>` in `passthru` and pass
them all to nix-update:

```nix
perSystem = {lib, pkgs, ...}: {
  idr.packages.my-tool = {
    package = pkgs.callPackage ./my-tool/package.nix {};
    update = pkgs.writeShellScript "update-my-tool" ''
      exec ${lib.getExe pkgs.nix-update} --flake my-tool \
        --custom-dep src-x86_64-linux --custom-dep src-aarch64-linux
    '';
  };
};
```

Prefer this to nix-update's `--system`, which needs a builder for that system.

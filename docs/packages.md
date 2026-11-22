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
idr-update-packages
```

The command runs each package's update script once, from the project root, as
declared for the development shell's system. It then builds the package if it
is available on that system. Packages are updated in parallel, as many at once
as the machine has CPU threads; `--threads` (`-t`) sets another limit. Each
package's output is printed when it finishes. Pass package names to update only
those. A failed package is reported at the end, after the others are updated.
Changes stay in the working tree for review.

The default update script runs `nix-update --flake <name>`, which updates the
version and the hashes of the package for the current system. When sources
differ between systems, the script must update every system's hash. For
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

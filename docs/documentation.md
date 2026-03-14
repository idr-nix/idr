## Documentation tools

To read the project guides and generated references, run from the project root:

```sh
nix run .#idr-open-docs
```

Set `BROWSER` to choose the browser and `BROWSER_ARGS` to pass space-separated
arguments.

To build without opening it:

```sh
nix build .#idr-mk-docs
```

The built documentation is at `result/html/index.html`.

### Search options

The development shell provides [nix-search-tv](https://github.com/3timeslazy/nix-search-tv)
configured with options from the project and supported flake inputs.
For example, to search with `fzf`:

```sh
nix-search-tv print | fzf --preview 'nix-search-tv preview {}'
```

Add `pkgs.fzf` to your [devshell packages](development-services.md#example-shell-packages-variables-and-commands)
if it is not installed. Run `nix-search-tv --help` for its other commands.

### Maintain guides and references

The book uses [mdBook](https://rust-lang.github.io/mdBook/). Add guides to
`SUMMARY.md` and configure the book in `book.toml`. Keep regular module guides in
their module folders.

Markdown files and book configuration are included automatically. List other
documentation files or directories relative to the project root:

```nix
perSystem.idr.documentation.assets = [
  "docs/assets"
  "LICENSE"
];
```

Option references are generated from exported modules, such as
`flake.modules.nixos` and `flake.modules.devshell`. Edit descriptions and examples
in the modules' option declarations.

IDR refreshes `docs/generated` on shell entry when the generator changes or the
directory is missing. To regenerate it manually, run from the project root in
the development shell:

```sh
idr-generate-docs
```

### Include generated Markdown

If a package generates Markdown, copy it into the book during the build.
For example, if `packages.mk-api-docs` produces `api.md`, add this to a flake
module:

```nix
_: {
  perSystem = {config, options, ...}: {
    idr.documentation.mk-docs =
      options.idr.documentation.mk-docs.default.overrideAttrs (old: {
        preBuild = (old.preBuild or "") + ''
          mkdir -p docs
          cp ${config.packages.mk-api-docs}/api.md docs/api.md
        '';
      });
  };
}
```

Add `[API](docs/api.md)` to `SUMMARY.md`, then build as usual.

### Document a library

To generate documentation from function comments, add the library to
`idr.documentation.nixdoc.libs`. For example, a module at
`nix/documentation/flake-module.nix` can document `nix/lib/helpers.nix`:

```nix
_: {
  perSystem = {...}: {
    idr.documentation.nixdoc.libs = [
      {
        path = ../lib/helpers.nix;
        prefix = "lib";
      }
    ];
  };
}
```

Use [nixdoc's comment format](https://github.com/nix-community/nixdoc#comment-format)
in the library. The result is written to `docs/generated/lib.md`.

For modules that need extra arguments during documentation generation, set
`perSystem.idr.documentation.specialArgs.nixos`, or the corresponding module
class.

Documentation helpers are enabled by default. Set
`perSystem.idr.documentation.enable = false` to disable them.

## Generated project files

You can keep tool configuration in Nix using `perSystem.idr.files`. IDR writes
these files into the project directory when you enter the development shell.

For example, `nix/project-files/flake-module.nix` could generate an
`.editorconfig` and a JSON configuration file:

```nix
_: {
  perSystem = {pkgs, ...}: {
    idr.files = {
      ".editorconfig".content = ''
        root = true

        [*]
        indent_style = space
        indent_size = 2
      '';
      ".config/example-app.json" = {
        content = pkgs.writers.writeJSON "example-app.json" {
          logLevel = "info";
        };
        copy = true;
      };
    };
  };
}
```

`content` can be a string or a file produced by a derivation. The default is a
symlink to the Nix store. Set `copy = true` when a tool needs a regular file, or
when you want to commit the generated contents to Git.

Add the module to Git, then enter the development shell:

```sh
git add nix/project-files/flake-module.nix
nix develop
```

IDR checks the files on each shell entry and restores missing or changed files.
To change a generated file, edit its Nix declaration.

### Run an action after writing

Use `postWrite` to run a command after IDR writes a file. It runs from the project
root. The command is a Bash fragment, which can invoke a Nushell script.

For example, add this inside `perSystem` to generate an application configuration
using `PRJ_DATA_DIR` from the current shell:

```nix
idr.files.".data/example-app.template.json" = {
  content = ''{"logLevel": "info"}'';
  postWrite = "${pkgs.writers.writeNu "render-example-config" ''
    mkdir $env.PRJ_DATA_DIR
    open ($env.PRJ_ROOT | path join ".data/example-app.template.json")
      | insert dataDir ($env.PRJ_DATA_DIR | path join "example-app")
      | to json
      | save --force ($env.PRJ_DATA_DIR | path join "example-app.json")
  ''}";
};
```

The script writes a separate file so the generated template still matches its
Nix declaration.

`postWrite` runs only when IDR writes the file. Changing the command or an
environment variable alone does not rerun it. For work needed on every shell
entry, use a [devshell startup action](development-services.md#example-setup-on-shell-entry)
with `deps = ["idr-write-files"]`.

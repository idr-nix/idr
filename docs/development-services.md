## Development services and tools

Use `idr` to run local development processes. You can also add tools,
environment variables, setup actions, and Git hooks to the development shell.

The configurations below are independent examples to adapt to your project.
Each can live in a flake module under `nix/<feature>/flake-module.nix`. The first
example shows a complete module; later Nix snippets show only its `perSystem`
contents.

### Example: a local documentation server

This example serves the project's `docs/` directory at `http://127.0.0.1:8080`.
It could live in `nix/local-docs/flake-module.nix`:

```nix
_: {
  perSystem = {pkgs, ...}: {
    process-compose.idr.settings.processes.docs-server.command =
      "${pkgs.python3}/bin/python -m http.server 8080 --bind 127.0.0.1 --directory docs";
  };
}
```

To load this example, stage the new file and enter the updated shell:

```sh
git add nix/local-docs/flake-module.nix
nix develop
```

### Manage configured processes

From the project root, run `idr` to open the Process Compose terminal UI.
Or start it in the background and follow the example server's output:

```sh
idr -D
idr process logs -f docs-server
```

Use `idr attach` to open the running project's terminal UI. Individual processes
can be controlled with `idr process start`, `stop`, or `restart`, followed by
the process name. Run `idr down` to stop Process Compose and all its processes.

Setting `disabled = true` on a process makes it wait for an explicit start.
After editing process configuration, re-enter the development shell and restart
Process Compose to load it.

### Example: a Redis service

This example uses a Redis module from upstream
[services-flake](https://community.flake.parts/services-flake/services) to create
a process named `cache`, listening on `127.0.0.1:6380`:

```nix
process-compose.idr.services.redis.cache = {
  enable = true;
  port = 6380;
  dataDir = ".data/redis";
};
```

Relative data paths are resolved from where `idr` starts. Concurrent instances
need non-conflicting ports and separate data directories; use host-specific data
paths for shared checkouts.

### Example: shell packages, variables, and commands

This example uses upstream [devshell](https://numtide.github.io/devshell/) to add
curl, set `APP_ENV`, and provide a Nushell command for checking patch whitespace:

```nix
devshells.default = {
  packages = [pkgs.curl];
  env = [
    {
      name = "APP_ENV";
      value = "development";
    }
  ];
  commands = [
    {
      name = "check-whitespace";
      help = "Check patch whitespace";
      package = pkgs.writers.writeNuBin "check-whitespace" ''
        ^${pkgs.git}/bin/git diff --check
      '';
    }
  ];
};
```

Commands appear in the shell's `menu`. Local environment variables can be set in
`.env`, which IDR sources as Bash.

### Project SSH configuration

Add project SSH settings through `devshells.default.idr.sshConfig` inside
`perSystem`. For example:

```nix
devshells.default.idr.sshConfig = ''
  Host build-host
    HostName 192.0.2.20
    User deploy
'';
```

The shell's `ssh` wrapper applies project settings before user and system
configuration for all SSH connections. Command-line options take precedence.
Connection multiplexing is disabled by default (`ControlMaster no` and
`ControlPath none`).

### Example: setup on shell entry

[Devshell](https://numtide.github.io/devshell/) startup actions run when the shell
is activated, including through direnv. This example creates a cache directory
under `PRJ_DATA_DIR`:

```nix
devshells.default.devshell.startup.prepare-cache.text =
  "${pkgs.writers.writeNu "prepare-cache" ''
    mkdir ($env.PRJ_DATA_DIR | path join "cache")
  ''}";
```

An action's `text` is a Bash command; here it invokes a Nushell script.
An action's `deps` can order it after another action, such as
`["idr-write-files"]` when it needs [generated files](generated-files.md).

### Example: a formatting Git hook

This example enables Alejandra on commit and adds pre-commit for manual runs:

```nix
pre-commit.settings.hooks.alejandra.enable = true;
devshells.default.packages = [pkgs.pre-commit];
```

The hooks are installed on shell entry. To run them against all files:

```sh
pre-commit run --all-files
```

To include enabled hooks in flake checks, set `pre-commit.check.enable = true`.

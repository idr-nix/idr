# IDR

IDR (Infrastructure Done Right) is a NixOS-based infrastructure framework that aims to provide a unified, reproducible, and secure foundation for managing servers and services - from initial setup to ongoing operations.  
The name reflects an opinionated but pragmatic approach to infrastructure, not a claim to be the one true way.

## Getting started

### Prerequisites

Mandatory (must already be installed on your system):
- [Git](https://git-scm.com/), configured for SSH access to GitHub - used to fetch the repository and manage changes
- [Nix](https://nixos.org/download/) with [flakes](https://nixos.wiki/wiki/Flakes) enabled - required to evaluate and use this project  
  For Debian, RPM-based, and pacman-based systems, the community installers at [nix-community.github.io/nix-installers](https://nix-community.github.io/nix-installers/) are worth considering.

Recommended but optional:
- [direnv](https://direnv.net/) - should already be installed and [configured with shell hooks](https://direnv.net/docs/hook.html) so the development environment loads automatically when entering the project directory

Without direnv, enter the project's development shell with `nix develop` before running IDR commands, or use `nix develop -c ...`.

### New flake

If your project does not have a flake yet:
```bash
nix run "git+ssh://git@github.com/idr-nix/idr" -- idr-mk-project path/to/project
```

Enter the generated project:
```sh
cd path/to/project
```

If you use direnv, allow the generated development environment:
```sh
direnv allow
```

### Existing flake

Integrate with flake parts: https://flake.parts/getting-started.html#existing-flake

Add or merge these entries into the existing `inputs` set.
```nix
idr = {
  url = "git+ssh://git@github.com/idr-nix/idr?shallow=1";
  inputs = {
    nixpkgs.follows = "nixpkgs";
    nixpkgs-unstable.follows = "nixpkgs-unstable";
    systems.follows = "systems";
    team.follows = "team";
  };
};
team = {
  url = "file+file:///dev/null";
  flake = false;
};
nixpkgs.url = "git+ssh://git@github.com/NixOS/nixpkgs?shallow=1&ref=nixos-26.05";
nixpkgs-unstable.url = "git+ssh://git@github.com/NixOS/nixpkgs?shallow=1&ref=nixos-unstable";
flake-parts.url = "git+ssh://git@github.com/hercules-ci/flake-parts?shallow=1";
systems.url = "git+ssh://git@github.com/nix-systems/default?shallow=1";
```

Prefix the existing `mkFlake` callback argument pattern with `top @`. Keep every argument already present in that pattern:
```nix
inputs.flake-parts.lib.mkFlake {inherit inputs;} (top @ {
  # Keep every existing callback argument here.
  ...
}: let
  flakeModules = inputs.idr.lib.importFlakeModules ./nix top;
in {
  idr.projectName = "my-project";
  flake.modules.flake = flakeModules;
  imports =
    [] # Replace with the existing imports list, if any.
    ++ (inputs.nixpkgs.lib.attrValues flakeModules)
    ++ [inputs.idr.modules.flake.idr];

  # Keep the existing mkFlake configuration here.
});
```

IDR also defines `packages.default`; an existing definition may cause a duplicate-definition error.

If you use direnv and the project already has an `.envrc`, ensure it activates the flake development environment. For example, add:
```sh
use flake .
```

`idr-mk-project` preserves existing `.envrc` and `.env` files. The development shell sources `.env` as Bash.

and run `nix run "git+ssh://git@github.com/idr-nix/idr" -- idr-mk-project .`

## Next steps

- [concepts](./docs/concepts.md)
- [team-input](./docs/team-input.md)
- [idr-mk-machine](./docs/mk-machine.md)
- [Installation (idr-anywhere)](./docs/installation.md)
- [Disk images (idr-mk-images)](./docs/mk-images.md)
- [Disk unlocking (idr-unlock-disks)](./docs/unlock-disks.md)
- [Automatic disk unlocking](./nix/disk-unlock/README.md)
- [Deployment](./docs/deployment.md)
- [Key rotation](./docs/key-rotation.md)
- [Certificates](./nix/idr/certs/README.md)
- [Backups](./nix/backup/README.md)
- [Local VMs](./docs/local-vms.md)
- [Local networking and workspaces](./docs/local-networking.md)
- [Development services](./docs/development-services.md)
- [Runtime secrets](./nix/secrets/README.md)
- [Service ports](./docs/ports.md)
- [Generated project files](./docs/generated-files.md)
- [Server presets and containers](./nix/preset/README.md)
- [Documentation tools](./docs/documentation.md)
- [idr-mk-role](./docs/mk-role.md)
- [idr-mk-module](./docs/mk-module.md)
- [LDAP](./nix/ldap/README.md)
- [etcd](./nix/etcd/README.md)

## License

Licensed under the [MIT license](LICENSE).

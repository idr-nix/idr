# The project's generated SOPS rules let the machines that configure a mesh
# machine's etcd user decrypt its password file, and only that file. Evaluated
# only: the test machines share one age identity, so they cannot show it.
{
  top,
  lib,
  system,
}: let
  project = ./fixtures/rbac-project;
  secrets = name: project + "/nix/machine/${name}/secrets.enc.json";
  machine = name: id: {
    config = {
      networking.hostName = name;
      idr.preset.base = {
        enable = true;
        inherit id;
        defaultSopsFile = secrets name;
        sopsRecipientMachines = [];
      };
    };
  };
  rbacHost = machine "rbac-host" "aaaaaaaaaaaa";
  passwordFile = project + "/nix/machine/mesh-host/mesh-etcd.enc.json";
  meshHostWith = extra:
    (top.inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {inherit (top) inputs;};
      modules = [
        {
          imports = builtins.attrValues {inherit (top.self.modules.nixos) mesh sops secrets systemd;};
          idr.mesh = {
            enable = true;
            etcd = {
              endpoint = "http://main.etcd.internal:1023";
              username = "mesh-host";
              passwordSource = {
                sopsFile = passwordFile;
                key = "password";
              };
              rbacMachines = [rbacHost];
            };
          };
          system.services.app = {
            imports = [top.self.modules.service.mesh];
            idr.mesh.id = "222222222222";
            process.argv = ["true"];
          };
        }
        extra
      ];
    })
    .config;
  meshHost = meshHostWith {};
  # The machine's other secrets would become readable by its RBAC machines.
  # Generated machines name their secrets file through the base preset.
  sharedFile = meshHostWith {
    options.idr.preset.base.defaultSopsFile = lib.mkOption {type = lib.types.nullOr lib.types.path;};
    # Given as a string, while the password file is a path.
    config.idr.preset.base.defaultSopsFile = toString passwordFile;
  };
  refused = builtins.any (a: !a.assertion && lib.hasPrefix "idr.mesh.etcd.passwordSource.sopsFile" a.message) sharedFile.assertions;
  rules =
    (top.inputs.flake-parts.lib.mkFlake {
        inputs = {
          self = {
            outPath = toString project;
            nixosConfigurations = {
              mesh-host = lib.recursiveUpdate (machine "mesh-host" "bbbbbbbbbbbb") {config.idr.mesh = meshHost.idr.mesh;};
              rbac-host = rbacHost;
            };
          };
          inherit (top.inputs) nixpkgs;
        };
      } ({config, ...}: {
        imports = [(lib.modules.importApply ../../idr/sops/flake-module.nix top)];
        systems = [];
        flake.rules = config.idr.sops.creation_rules;
      }))
    .rules;
  key = name: (lib.importJSON (secrets name)).ssh_host_ed25519_key_age_pub_unencrypted;
  passwordRule = {
    priority = 1;
    rule = {
      path_regex = "^nix\\/machine\\/mesh\\-host\\/mesh\\-etcd\\.enc\\.json$";
      age = [(key "mesh-host") (key "rbac-host")];
    };
  };
in
  lib.assertMsg (builtins.elem passwordRule rules) "A mesh password file must be readable by its RBAC machines only."
  && lib.assertMsg refused "A mesh password file that holds other secrets must be refused."

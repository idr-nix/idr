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
  passwordFile = project + "/nix/machine/mesh-host/mesh-etcd.enc.json";
  nixosSystem = modules:
    (top.inputs.nixpkgs.lib.nixosSystem {
      inherit system modules;
      specialArgs = {inherit (top) inputs;};
    })
    .config;
  meshHostWith = recipientMachines:
    nixosSystem [
      {
        imports = builtins.attrValues {inherit (top.self.modules.nixos) mesh sops secrets systemd;};
        idr.mesh = {
          enable = true;
          etcd = {
            endpoint = "http://main.etcd.internal:1023";
            username = "mesh-host";
            password = {
              sopsFile = passwordFile;
              key = "password";
              inherit recipientMachines;
            };
          };
        };
        system.services.app = {
          imports = [top.self.modules.service.mesh];
          idr.mesh.id = "222222222222";
          process.argv = ["true"];
        };
      }
    ];
  meshHost = meshHostWith [];
  # The RBAC machine reads the password from the source that meshRbac passes on.
  rbacHost = nixosSystem [
    {
      imports = builtins.attrValues {inherit (top.self.modules.nixos) etcd sops secrets;};
      idr.etcd.clusters.main.rbac =
        {
          endpoints = [{domain = "etcd.example.test";}];
          rootPassword = {
            path = "/run/test/root-password";
            group = "root";
            reloadTarget = "test.target";
            restartTarget = "test.target";
          };
        }
        // top.idr-lib.meshRbac {mesh-host.config = meshHost;};
    }
  ];
  # A project machine with the SOPS files that a configuration reads.
  reading = name: id: configuration:
    lib.recursiveUpdate (machine name id) {
      config.idr.secrets-sops-files = configuration.idr.secrets-sops-files;
    };
  rulesFor = nixosConfigurations:
    (top.inputs.flake-parts.lib.mkFlake {
        inputs = {
          self = {
            outPath = toString project;
            inherit nixosConfigurations;
          };
          inherit (top.inputs) nixpkgs;
        };
      } ({config, ...}: {
        imports = [(lib.modules.importApply ../../idr/sops/flake-module.nix top)];
        systems = [];
        flake.rules = config.idr.sops.creation_rules;
      }))
    .rules;
  # The RBAC machine of the same project is added because it reads the file.
  automatic = rulesFor {
    mesh-host = reading "mesh-host" "bbbbbbbbbbbb" meshHost;
    rbac-host = reading "rbac-host" "aaaaaaaaaaaa" rbacHost;
  };
  # An RBAC machine of another project is added because the source lists it.
  listed = rulesFor {
    mesh-host = reading "mesh-host" "bbbbbbbbbbbb" (meshHostWith [(machine "rbac-host" "aaaaaaaaaaaa")]);
  };
  # The machine's other secrets would become readable by its RBAC machine.
  # Given as a string, while the password file is a path.
  sharedFile = rulesFor {
    mesh-host = lib.recursiveUpdate (reading "mesh-host" "bbbbbbbbbbbb" meshHost) {
      options.sops.defaultSopsFile.isDefined = true;
      config.sops.defaultSopsFile = toString passwordFile;
    };
    rbac-host = reading "rbac-host" "aaaaaaaaaaaa" rbacHost;
  };
  refused = !(builtins.tryEval (builtins.deepSeq sharedFile sharedFile)).success;
  key = name: (lib.importJSON (secrets name)).ssh_host_ed25519_key_age_pub_unencrypted;
  passwordRule = {
    priority = 1;
    rule = {
      path_regex = "^nix\\/machine\\/mesh\\-host\\/mesh\\-etcd\\.enc\\.json$";
      age = [(key "mesh-host") (key "rbac-host")];
    };
  };
in
  lib.assertMsg (builtins.elem passwordRule automatic) "A mesh password file must be readable by the RBAC machines of its project."
  && lib.assertMsg (builtins.elem passwordRule listed) "A mesh password file must be readable by the machines its source lists."
  && lib.assertMsg refused "A mesh password file that holds other secrets must be refused."

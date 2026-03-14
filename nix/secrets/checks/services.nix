{
  pkgs,
  inputs,
  self,
  ...
}: let
  inherit (pkgs) lib;
  assets = inputs.sops-nix + "/pkgs/sops-install-secrets/test-assets";
  hostKey = "/etc/ssh/idr/test-host-key";
  top = {
    inputs = inputs // {idr = self;};
    idr-lib = self.lib;
  };
  secretModule = import ../nixos-module.nix top;

  # Reverse alphabetical dependencies exercise the generated-secret ordering.
  sources = secrets: sourceKey: {
    z-source = {
      sopsFile = assets + "/secrets.yaml";
      key = sourceKey;
    };
    y-stdout = {
      secrets.VALUE = secrets.z-source;
      exec = ''
        printf 'run\n' >> /run/secret-test/stdout-runs
        printf 'stdout:%s' "$VALUE"
      '';
    };
    a-template = {
      secrets.VALUE = secrets.y-stdout;
      template = "[$VALUE] $UNDECLARED";
    };
    output-file = {
      secrets.VALUE = secrets.z-source;
      exec = ''
        printf 'run\n' >> /run/secret-test/output-file-runs
        printf 'fixed output' > "$out"
        printf 'stdout must be ignored'
      '';
    };
    trailing = {
      exec = ''printf 'quote" backslash\\ dollar$\nsecond line\n\n' '';
    };
    environment.secrets = {
      VALUE = secrets.z-source;
      TRAILING = secrets.trailing;
    };
    retry = {
      secrets.VALUE = {
        path = "/run/secret-test/input";
        group = "keys";
        reloadTarget = "secret-test-input-reload.target";
        restartTarget = "secret-test-input-restart.target";
      };
      exec = ''
        printf '%s' "$VALUE" > "$out"
        if [[ -e /run/secret-test/fail ]]; then
          printf 'incomplete stdout'
          exit 1
        fi
      '';
    };
  };

  testServices = {config, ...}: {
    systemd.tmpfiles.rules = [
      "d /run/secret-test 0700 root root -"
      "f /run/secret-test/input 0600 root root - first"
    ];
    systemd.targets.multi-user.wants = ["templated@reload.service" "templated@restart.service"];
    systemd.services =
      (lib.genAttrs ["reload-consumer" "restart-consumer"] (name: let
        target =
          if name == "reload-consumer"
          then config.idr.secrets.a-template.reloadTarget
          else config.idr.secrets.a-template.restartTarget;
      in {
        wantedBy = ["multi-user.target" target];
        after = ["idr-secrets.service"];
        partOf = [target];
        unitConfig.ReloadPropagatedFrom = lib.optional (name == "reload-consumer") target;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          cat ${config.idr.secrets.a-template.path} >> /run/secret-test/${name}
          printf '\n' >> /run/secret-test/${name}
        '';
        reload = lib.mkIf (name == "reload-consumer") ''
          cat ${config.idr.secrets.a-template.path} >> /run/secret-test/${name}
          printf '\n' >> /run/secret-test/${name}
          printf 'reload\n' >> /run/secret-test/reloads
        '';
      }))
      // {
        idr-secrets = {
          after = ["systemd-tmpfiles-setup.service"];
          requires = ["systemd-tmpfiles-setup.service"];
        };
        "templated@" = {
          after = ["idr-secrets.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Environment = "INSTANCE=%i";
          };
          script = ''
            printf 'start:' >> /run/secret-test/template-"$INSTANCE"
            cat ${config.idr.secrets.z-source.path} >> /run/secret-test/template-"$INSTANCE"
            printf '\n' >> /run/secret-test/template-"$INSTANCE"
          '';
          reload = ''
            printf 'reload:' >> /run/secret-test/template-"$INSTANCE"
            cat ${config.idr.secrets.z-source.path} >> /run/secret-test/template-"$INSTANCE"
            printf '\n' >> /run/secret-test/template-"$INSTANCE"
          '';
        };
      };
  };
in
  pkgs.testers.runNixOSTest {
    name = "idr-secret-services";
    globalTimeout = 10 * 60;

    nodes.machine = {config, ...}: {
      imports = [
        inputs.sops-nix.nixosModules.sops
        secretModule
        (import ../../preset/base/nixos-containers.nix top)
        testServices
      ];

      # Exercise container integration without the unrelated host base preset.
      options.idr.preset.base.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };

      config = {
        virtualisation.memorySize = 2048;
        virtualisation.cores = 2;
        system.switch.enable = true;
        environment.etc."ssh/idr/test-host-key" = {
          source = assets + "/ssh-ed25519-key";
          mode = "0600";
        };
        sops = {
          age.sshKeyPaths = [hostKey];
          gnupg.sshKeyPaths = [];
          useSystemdActivation = false;
          secrets.z-source = {
            # Container inheritance must retain real units and template instances,
            # while dropping units that exist only on the host.
            restartUnits = ["host-only.service" "templated@restart.service"];
            reloadUnits = ["host-only.service" "templated@reload.service"];
          };
        };
        idr.secrets-source =
          (sources config.idr.secrets "test_key")
          // {obsolete.exec = "printf obsolete";};

        users.users.reader = {
          isNormalUser = true;
          extraGroups = ["keys_a-template"];
        };
        systemd.services.host-only.serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
        containers.consumer.config = {
          imports = [testServices];
          idr.preset.base.enable = lib.mkForce false;
          sops.useSystemdActivation = false;
          system.stateVersion = "26.05";
        };

        specialisation.updated.configuration = {config, ...}: {
          idr.secrets-source = lib.mkForce (sources config.idr.secrets "nested/test/file");
        };
        specialisation.service-mode.configuration = {
          sops.useSystemdActivation = lib.mkForce true;
          containers.consumer.config.sops.useSystemdActivation = lib.mkForce true;
        };
      };
    };

    testScript = builtins.readFile ./services/test.py;
  }

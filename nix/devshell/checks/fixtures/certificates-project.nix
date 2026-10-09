{
  top,
  project,
  useVM,
}: {
  config,
  lib,
  ...
}: let
  inherit (config.node.pkgs.stdenv.hostPlatform) system;
  machineId = top.self.nixosConfigurations."example-${system}".config.idr.preset.base.id;
  acme = config.node.pkgs.path + "/nixos/tests/common/acme/server";
  pebbleConfig = config.node.pkgs.writeText "pebble.json" (builtins.toJSON {
    pebble = {
      listenAddress = "127.0.0.1:14000";
      managementListenAddress = "127.0.0.1:15000";
      # The issued test output is reused by the runtime check; keep cached fixtures valid.
      certificateValidityPeriod = 20 * 365 * 24 * 60 * 60;
      certificate = "${acme}/acme.test.cert.pem";
      privateKey = "${acme}/acme.test.key.pem";
      httpPort = 8080;
      tlsPort = 5001;
    };
  });
in {
  imports =
    (with top.self.modules.nixosTest; [base operator ssh-git])
    ++ [
      (lib.modules.importApply ./operator-project.nix {
        inherit project machineId;
      })
    ];

  globalTimeout = 25 * 60;
  idr.test.storePaths = [top.self.packages.${system}.default];

  defaults = {pkgs, ...}: {
    networking.hosts."127.0.0.1" = ["acme.test" "first.example.test" "second.example.test" "third.example.test" "fourth.example.test"];
    environment.systemPackages = [pkgs.openssl pkgs.sops];
    environment.variables = {
      LEGO_SERVER = "https://acme.test:14000/dir";
      IDR_TEST_ACME_CA = "${acme}/ca.cert.pem";
    };
    systemd.tmpfiles.rules = ["d /var/lib/acme-http 0755 operator users -"];
    services.nginx = {
      enable = true;
      # Lego inherits the updater's private umask; serve challenges as their owner.
      user = "operator";
      group = "operator";
      virtualHosts.acme-challenges = {
        listen = [
          {
            addr = "127.0.0.1";
            port = 8080;
          }
        ];
        root = "/var/lib/acme-http";
      };
    };
    systemd.services.pebble = {
      wantedBy = ["multi-user.target"];
      environment = {
        PEBBLE_VA_NOSLEEP = "1";
        PEBBLE_WFE_NONCEREJECT = "0";
      };
      serviceConfig.ExecStart = "${pkgs.pebble}/bin/pebble -config ${pebbleConfig}";
    };
  };

  containers = lib.optionalAttrs (!useVM) {machine = {};};
  nodes = lib.optionalAttrs useVM {
    machine = {
      virtualisation = {
        memorySize = 8192;
        cores = 4;
      };
      networking.useDHCP = false;
    };
  };
}

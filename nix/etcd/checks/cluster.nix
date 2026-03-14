{
  pkgs,
  inputs,
  self,
  ...
}: let
  inherit (pkgs) lib;
  inherit (import ./fixtures.nix {inherit pkgs;}) members credentials;
  top = {
    inputs = inputs // {idr = self;};
    idr-lib = self.lib;
  };
  memberNames = builtins.attrNames members;
  secretTarget = "etcd-test-secrets-restart.target";
  rawSecret = name: {
    path = "/run/etcd-test-secrets/${name}";
    group = "root";
    reloadTarget = "etcd-test-secrets-reload.target";
    restartTarget = secretTarget;
  };
  endpoints = map (name: {
    domain = "${name}.example.test";
    port = members.${name}.publicPort;
    ip =
      if name == "gamma"
      then members.${name}.ipv6
      else members.${name}.ipv4;
  }) ["beta" "gamma"];
  endpointURLs = lib.concatMapStringsSep "," (endpoint: "https://${endpoint.domain}:${toString endpoint.port}") endpoints;
  rbac = secrets: updated: {
    inherit endpoints;
    caCert = "${credentials}/ca";
    rootPassword = secrets.root-password;
    roles =
      if updated
      then {
        read.permissions = [
          {
            target = "/new/";
            prefix = true;
          }
        ];
        write.permissions = [
          {
            target = "/new/";
            prefix = true;
            access = "readwrite";
          }
          {
            target = {
              from = "/range/b";
              to = "/range/c";
            };
          }
        ];
        added.permissions = [{target = "/added";}];
      }
      else {
        read.permissions = [
          {
            target = "/app/";
            prefix = true;
          }
        ];
        write.permissions = [
          {
            target = "/app/";
            prefix = true;
            access = "write";
          }
          {
            target = "/exact";
            access = "readwrite";
          }
          {
            target = {
              from = "/range/a";
              to = "/range/d";
            };
            access = "readwrite";
          }
          {
            target = "/ÿ";
            prefix = true;
            access = "readwrite";
          }
        ];
        obsolete.permissions = [
          {
            target = "/obsolete";
            access = "readwrite";
          }
        ];
      };
    users =
      {
        writer = {
          password =
            secrets.${
              if updated
              then "writer-password-updated"
              else "writer-password"
            };
          roles = ["write"] ++ lib.optional (!updated) "read";
        };
        reader = {
          password = secrets.reader-password;
          roles = ["read"] ++ lib.optional updated "added";
        };
      }
      // (
        if updated
        then {
          newcomer = {
            password = secrets.newcomer-password;
            roles = ["added"];
          };
        }
        else {
          obsolete = {
            password = secrets.obsolete-password;
            roles = ["obsolete"];
          };
        }
      );
  };
  node = name: {config, ...}: let
    member = members.${name};
    peers = lib.filter (peer: peer != name) memberNames;
    secretFiles = [
      "cert"
      "key"
      "wireguard-key"
      "wireguard-psk"
      "root-password"
      "writer-password"
      "writer-password-updated"
      "reader-password"
      "obsolete-password"
      "newcomer-password"
    ];
  in {
    imports = [
      inputs.sops-nix.nixosModules.sops
      (lib.modules.importApply ../../secrets/nixos-module.nix top)
      (lib.modules.importApply ../nixos-module.nix top)
    ];
    options.testLocalEtcdMembers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      internal = true;
    };
    config = {
      virtualisation = {
        memorySize = 1024;
        cores = 2;
        # The VM module replaces the normal filesystem declarations.
        fileSystems = lib.mkIf config.testLocalEtcdMembers (lib.genAttrs
          (map (member: "/var/lib/private/idr-etcd-${member}") ([name] ++ lib.optional (name == "alpha") "aardvark"))
          (mount: {
            device = "/srv/etcd/${lib.removePrefix "/var/lib/private/idr-etcd-" mount}";
            fsType = "none";
            options = ["bind"];
          }));
      };
      system.activationScripts.etcd-test-data.text = ''
        mkdir -p /srv/etcd/${name} ${lib.optionalString (name == "alpha") "/srv/etcd/aardvark"}
      '';
      system.switch.enable = true;
      nix.settings.sandbox = true;
      networking.useNetworkd = true;
      networking.nftables.enable = true;
      networking.interfaces.eth1 = {
        ipv4.addresses = [
          {
            address = member.ipv4;
            prefixLength = 24;
          }
        ];
        ipv6.addresses = [
          {
            address = member.ipv6;
            prefixLength = 64;
          }
        ];
      };
      networking.hosts =
        lib.mapAttrs' (
          peer: value:
            lib.nameValuePair value.ipv4 ["${peer}.example.test"]
        )
        members
        // {"${members.beta.ipv4}" = ["beta.example.test" "wrong.example.test"];};
      environment.systemPackages = [pkgs.etcd pkgs.openssl pkgs.netcat-openbsd pkgs.iproute2 pkgs.wireguard-tools];

      # Fixture inputs are root-only runtime files. The real IDR secret generator
      # supplies their credential references and propagates subsequent refreshes.
      systemd.targets = {
        etcd-test-secrets-restart = {};
        etcd-test-secrets-reload = {};
      };
      systemd.services.etcd-test-secrets = {
        wantedBy = ["sysinit.target" secretTarget];
        before = ["idr-secrets.service" "sysinit.target" secretTarget];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "etcd-test-secrets";
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = true;
        };
        path = [pkgs.coreutils];
        script = ''
          install -m 0400 ${credentials}/${name}-cert-1 /run/etcd-test-secrets/cert
          install -m 0400 ${credentials}/${name}-key /run/etcd-test-secrets/key
          install -m 0400 ${credentials}/${name}-wireguard-key /run/etcd-test-secrets/wireguard-key
          ${lib.concatMapStringsSep "\n" (file: ''
            install -m 0400 ${credentials}/${file} /run/etcd-test-secrets/${file}
          '') (lib.drop 3 secretFiles)}
        '';
      };
      idr.secrets-source = lib.genAttrs secretFiles (file: {
        secrets.VALUE = rawSecret file;
        exec = ''printf '%s' "$VALUE"'';
      });

      idr.etcd = lib.mkIf config.testLocalEtcdMembers {
        instances.${name} = {
          dataDir = "/srv/etcd/${name}";
          cert = config.idr.secrets.cert;
          certKey = config.idr.secrets.key;
          clusterToken = "idr-etcd-test";
          publicHostname = "${name}.example.test";
          inherit (member) publicPort;
          peers = lib.genAttrs peers (_: {});
          allowedIPs = ["${members.alpha.ipv4}/32" "${members.alpha.ipv6}/128"];
        };
        instances.disabled.enable = false;
        instances.aardvark = lib.mkIf (name == "alpha") {
          dataDir = "/srv/etcd/aardvark";
          cert = config.idr.secrets.cert;
          certKey = config.idr.secrets.key;
          clusterToken = "independent-cluster";
          publicHostname = "alpha.example.test";
          publicPort = 2381;
        };
        privateNetwork = {
          listenPort = member.wireguardPort;
          privKey = config.idr.secrets.wireguard-key;
          peers =
            map (peer: {
              endpoint = {
                # The alpha/gamma pair uses IPv6; all other pairs use IPv4.
                address =
                  members.${
                    peer
                  }.${
                    if builtins.elem "beta" [name peer]
                    then "ipv4"
                    else "ipv6"
                  };
                port = members.${peer}.wireguardPort;
              };
              pubKey = members.${peer}.publicKey;
              psk = config.idr.secrets.wireguard-psk;
              etcdPeers = [peer];
            })
            peers;
        };
      };
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "idr-etcd-cluster";
    globalTimeout = 10 * 60;
    nodes = lib.genAttrs memberNames (name: {
      imports =
        [(node name)]
        ++ lib.optional (name == "alpha") ({config, ...}: {
          idr.etcd.proxy.cluster = {
            inherit endpoints;
            caCert = "${credentials}/ca";
          };
          idr.etcd.rbac = [(rbac config.idr.secrets false)];
          specialisation.updated.configuration = {config, ...}: {
            # Two remote members retain quorum. This configuration deliberately
            # has neither a local instance nor WireGuard secret/port options.
            testLocalEtcdMembers = false;
            idr.etcd.rbac = lib.mkForce [(rbac config.idr.secrets true)];
          };
        });
    });
    testScript = ''
      import json
      members = json.loads(${builtins.toJSON (builtins.toJSON members)})
      private_addresses = json.loads(${builtins.toJSON (builtins.toJSON (lib.genAttrs memberNames (self.lib.mkIPv6 "fdc1:ae6a:1782")))})
      credentials = "${credentials}"
      rbac_unit = "idr-etcd-rbac-${self.lib.shortHash 8 endpointURLs}.service"
      ${builtins.readFile ./cluster/test.py}
    '';
  }

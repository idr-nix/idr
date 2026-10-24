{top}: {lib, ...}: let
  members = ["alpha" "beta" "gamma"];
  addresses = {
    alpha = "192.168.1.1";
    beta = "192.168.1.2";
    gamma = "192.168.1.3";
  };
  ipv6Addresses = {
    alpha = "2001:db8:1::1";
    beta = "2001:db8:1::2";
    gamma = "2001:db8:1::3";
  };
  publicKeys = builtins.fromJSON (builtins.readFile ./fixtures/etcd/wireguard-public-keys.json);
in {
  imports = [top.self.modules.nixosTest.disk-storage];

  globalTimeout = 10 * 60;
  defaults = {
    config,
    pkgs,
    ...
  }: {
    imports = with top.self.modules.nixos; [sops secrets etcd];
    _module.args.inputs = top.inputs;
    virtualisation = {
      cores = 1;
      memorySize = 1024;
      # Retain the service module's real bind mounts instead of the VM defaults
      # replacing the entire fileSystems option. The root and store below are
      # ordinary test VM mounts; the etcd bind mounts come from the module.
      fileSystems = lib.mkForce {};
      writableStore = lib.mkDefault false;
    };
    fileSystems =
      {
        "/" = {
          device = config.virtualisation.rootDevice;
          fsType = "ext4";
        };
        "/nix/store" =
          if config.virtualisation.writableStore
          then {
            overlay = {
              lowerdir = ["/nix/.ro-store"];
              upperdir = "/nix/.rw-store/upper";
              workdir = "/nix/.rw-store/work";
            };
          }
          else {
            device = "/nix/.ro-store";
            fsType = "none";
            options = ["bind"];
          };
        "/nix/.rw-store" = lib.mkIf (config.virtualisation.writableStore && config.virtualisation.writableStoreUseTmpfs) {
          fsType = "tmpfs";
          options = ["mode=0755"];
          neededForBoot = true;
        };
      }
      // lib.mapAttrs' (tag: share:
        lib.nameValuePair share.target {
          device = tag;
          fsType = "9p";
          neededForBoot = true;
          options =
            ["trans=virtio" "version=9p2000.L" "msize=${toString config.virtualisation.msize}" "x-systemd.requires=modprobe@9pnet_virtio.service"]
            ++ lib.optional (tag == "nix-store") "cache=${config.virtualisation.nixStore9pCache}";
        })
      config.virtualisation.sharedDirectories;
    # Only the controller that switches generations needs Nix in the guest.
    nix.enable = config.virtualisation.writableStore;
    networking.useDHCP = false;
    environment.systemPackages = [pkgs.etcd pkgs.jq pkgs.wireguard-tools];
    environment.sessionVariables = {
      # CLI trust is explicit, so services must honor their own caCert options.
      ETCDCTL_CACERT = "${./fixtures/etcd/ca.pem}";
      ETCDCTL_ENDPOINTS = lib.concatMapStringsSep "," (name: "https://etcd-${name}.example.test:2379") members;
      ETCDCTL_DIAL_TIMEOUT = "2s";
      ETCDCTL_COMMAND_TIMEOUT = "5s";
    };
  };
  nodes = lib.genAttrs members (name: {config, ...}: let
    others = lib.filter (peer: peer != name) members;
    pair = peer: lib.concatStringsSep "-" (lib.sort builtins.lessThan [name peer]);
    secrets =
      ["${name}-wireguard-key" "${name}-cert" "${name}-cert-key"]
      ++ map (peer: "${pair peer}-psk") others;
  in {
    # All encrypted values and this identity are deliberately public test fixtures.
    sops.age = {
      keyFile = "/var/lib/sops-nix/key.txt";
      sshKeyPaths = [];
    };
    sops.gnupg.sshKeyPaths = [];
    sops.useSystemdActivation = true;
    systemd.tmpfiles.rules = [
      "d /var/lib/sops-nix 0700 root root -"
      "C /var/lib/sops-nix/key.txt 0400 root root - ${./fixtures/runtime-secrets/key.txt}"
    ];
    systemd.services.sops-install-secrets.after = ["systemd-tmpfiles-setup.service"];
    networking.hosts = lib.mapAttrs' (name: ip: lib.nameValuePair ip ["etcd-${name}.example.test"]) addresses;
    # Exercise both supported endpoint families and firewall implementations.
    networking.interfaces.eth1.ipv6.addresses = [
      {
        address = ipv6Addresses.${name};
        prefixLength = 64;
      }
    ];
    networking.nftables.enable = name == "gamma";
    # Each member has an actual persistent volume, as required by the docs.
    virtualisation.emptyDiskImages = [
      {
        size = 256;
        driveConfig.deviceExtraOpts.serial = "etcd-data";
      }
    ];
    fileSystems."/p1/etcd-${name}" = {
      device = "/dev/disk/by-id/virtio-etcd-data";
      fsType = "ext4";
      autoFormat = true;
    };
    idr.secrets-source = lib.genAttrs secrets (_: {
      sopsFile = ./fixtures/etcd/initial.enc.json;
      format = "json";
    });
    idr.etcd = {
      privateNetwork = {
        listenPort = 61010;
        privKey = config.idr.secrets."${name}-wireguard-key";
        peers =
          map (peer: {
            endpoint = {
              address =
                if name == "gamma" || peer == "gamma"
                then ipv6Addresses.${peer}
                else addresses.${peer};
              port = 61010;
            };
            pubKey = publicKeys.${peer};
            psk = config.idr.secrets."${pair peer}-psk";
            etcdPeers = lib.genAttrs (builtins.attrNames config.idr.etcd.clusters) (_: [peer]);
          })
          others;
      };
      clusters.main.instances.${name} = {
        dataDir = "/p1/etcd-${name}";
        cert = config.idr.secrets."${name}-cert";
        certKey = config.idr.secrets."${name}-cert-key";
        clusterToken = "public-documentation-test";
        publicHostname = "etcd-${name}.example.test";
        allowedIPs = ["192.168.1.0/24"];
        peers = lib.genAttrs others (_: {});
      };
    };
  });
}

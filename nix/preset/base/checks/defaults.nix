{
  pkgs,
  inputs,
  self,
}: let
  inherit (pkgs) lib;
  keys = import (inputs.nixpkgs + /nixos/tests/ssh-keys.nix) pkgs;
  machineId = "123456abcdef";
  top = {
    inputs = inputs // {idr = self;};
    idr-lib =
      self.lib
      // {
        team = {
          permanent = {
            sshPublicKey = keys.snakeOilPublicKey;
            sshAccess."server-${machineId}" = {};
          };
          temporary = {
            sshPublicKey = keys.snakeOilEd25519PublicKey;
            sshAccess."server-${machineId}".expiresAt = "2041-01-01T00:00:00Z";
          };
        };
      };
  };
  modules = [
    inputs.disko.nixosModules.disko
    inputs.sops-nix.nixosModules.sops
    inputs.impermanence.nixosModules.impermanence
    (lib.modules.importApply ../../nixos-module.nix top)
    self.modules.nixos.secrets
    self.modules.nixos.qemu-host
  ];
  containerImage = pkgs.dockerTools.buildLayeredImage {
    name = "idr-network-test";
    tag = "test";
    contents = [pkgs.busybox (pkgs.writeTextDir "www/index.html" "idr-network-ok\n")];
    config.Cmd = ["/bin/httpd" "-f" "-p" "[::]:8080" "-h" "/www"];
  };
in
  pkgs.testers.runNixOSTest {
    name = "idr-base-presets";
    globalTimeout = 300;
    node.pkgsReadOnly = false;
    nodes.server = {
      imports = modules;
      idr.preset.base.id = machineId;
      idr.preset.loopback.addresses = ["10.123.0.1/32" "fd42::123/128"];
      idr.qemu-host.enable = true;
      containers.example.config.system.stateVersion = "26.05";
      # This VM tests stage 2; the image test exercises the encrypted initrd.
      boot.initrd.network.ssh.enable = false;
      services.timesyncd.enable = false;
      services.openssh.settings.PerSourcePenalties = "no";
      nix.settings.sandbox = true;
      virtualisation.memorySize = 2048;
      environment.etc = {
        "test-permanent-key" = {
          source = keys.snakeOilPrivateKey;
          mode = "0600";
        };
        "test-temporary-key" = {
          source = keys.snakeOilEd25519PrivateKey;
          mode = "0600";
        };
        "test-container-image.tar.gz".source = containerImage;
      };
    };
    testScript = builtins.readFile ./defaults/test.py;
  }

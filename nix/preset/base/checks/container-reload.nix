{
  pkgs,
  inputs,
  self,
}: let
  inherit (pkgs) lib;
  keys = import (inputs.nixpkgs + /nixos/tests/ssh-keys.nix) pkgs;
  top = {
    inputs = inputs // {idr = self;};
    idr-lib = self.lib // {team = {};};
  };
in
  pkgs.testers.runNixOSTest {
    name = "idr-container-reload";
    globalTimeout = 300;
    node.pkgsReadOnly = false;
    nodes.server = {
      imports = [
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        inputs.impermanence.nixosModules.impermanence
        (lib.modules.importApply ../../nixos-module.nix top)
        self.modules.nixos.secrets
      ];
      idr.preset.base.id = "123456abcdef";
      boot.initrd.network.ssh.enable = false;
      users.users.root.openssh.authorizedKeys.keys = [keys.snakeOilPublicKey];
      system.switch.enable = true;
      nix.settings.sandbox = true;
      virtualisation = {
        memorySize = 1536;
        cores = 2;
      };

      systemd.tmpfiles.rules = ["d /var/lib/container-test 0755 root root -"];
      containers.example = {
        config = {
          system.stateVersion = "26.05";
          environment.etc."container-version".text = "original";
        };
        bindMounts."/run/host-data" = {
          hostPath = "/var/lib/container-test";
          isReadOnly = false;
        };
      };
      specialisation = {
        container-reload.configuration.containers.example.config.environment.etc."container-version".text =
          lib.mkForce "updated";
        container-restart.configuration.containers.example.bindMounts."/run/host-data".isReadOnly =
          lib.mkForce true;
      };
    };
    testScript = builtins.readFile ./container-reload/test.py;
  }

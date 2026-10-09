{top}: {
  imports = [top.self.modules.nixosTest.disk-storage];

  globalTimeout = 10 * 60;
  # The base preset and Disko add their normal Nixpkgs overlays.
  node.pkgsReadOnly = false;

  nodes.machine = {pkgs, ...}: {
    imports = builtins.attrValues top.self.modules.nixos;
    _module.args.inputs = top.inputs;

    virtualisation = {
      memorySize = 2048;
      cores = 2;
    };
    networking.useDHCP = false;
    idr.preset.base = {
      id = "24a1c017a17e";
      inherit (top) inputs;
    };
    # The test driver administers this VM; the example does not need remote access.
    services.openssh.enable = false;
    boot.initrd.network.ssh.enable = false;
    virtualisation.podman.enable = false;
    environment.systemPackages = [pkgs.curl];

    containers.example.config.system.stateVersion = "26.05";
  };
}

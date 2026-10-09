{
  top,
  useVM,
}: {lib, ...}: {
  imports = [top.self.modules.nixosTest.disk-storage];

  globalTimeout = 10 * 60;

  defaults = {
    imports = with top.self.modules.nixos; [sops secrets systemd];
    _module.args.inputs = top.inputs;

    # This identity is deliberately public and protects only synthetic test data.
    sops.age = {
      keyFile = "/var/lib/sops-nix/key.txt";
      sshKeyPaths = [];
    };
    systemd.tmpfiles.rules = [
      "d /var/lib/sops-nix 0700 root root -"
      "C /var/lib/sops-nix/key.txt 0400 root root - ${./fixtures/runtime-secrets/key.txt}"
    ];
    systemd.services.sops-install-secrets.after = ["systemd-tmpfiles-setup.service"];
    sops.gnupg.sshKeyPaths = [];
    sops.useSystemdActivation = true;
    idr.secrets-source.api-token = {
      sopsFile = ./fixtures/runtime-secrets/initial.enc.json;
      format = "json";
      key = "api_token";
    };

    users.users.my-app = {
      isSystemUser = true;
      group = "my-app";
    };
    users.groups.my-app = {};
    users.users.untrusted = {
      isNormalUser = true;
      group = "untrusted";
    };
    users.groups.untrusted = {};
  };

  containers = lib.optionalAttrs (!useVM) {machine = {};};
  nodes = lib.optionalAttrs useVM {
    machine = {
      virtualisation = {
        memorySize = 2048;
        cores = 2;
      };
      networking.useDHCP = false;
    };
  };
}

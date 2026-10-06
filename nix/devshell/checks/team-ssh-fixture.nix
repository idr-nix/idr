top: {lib, ...}: {
  globalTimeout = 10 * 60;
  node.pkgsReadOnly = false;

  # Expiry must be tested with a private clock, and revocation activates a new
  # generation. Neither operation is suitable for the nspawn test harness.
  nodes.machine = {
    config,
    pkgs,
    lib,
    ...
  }: let
    # Public upstream test identities, never credentials for a real machine.
    keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
    team = {
      Permanent = {
        sshPublicKey = keys.snakeOilPublicKey;
        sshAccess."machine-0123456789ab" = {};
      };
      Temporary = {
        sshPublicKey = keys.snakeOilEd25519PublicKey;
        sshAccess."machine-0123456789ab".expiresAt = "2027-09-07T18:00:00Z";
      };
    };
    testTop =
      top
      // {
        idr-lib =
          top.idr-lib
          // {
            team = builtins.removeAttrs team config.idr.test.revokedMembers;
          };
      };
  in {
    imports = [
      (lib.modules.importApply ../../preset/nixos-module.nix testTop)
      top.self.modules.nixos.disko
      top.self.modules.nixos.sops
    ];

    options.idr.test.revokedMembers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
    };

    config = {
      _module.args.inputs = top.inputs;
      idr.preset.base.id = "0123456789ab";
      users.users.root = {
        hashedPassword = "*";
        hashedPasswordFile = lib.mkForce null;
      };
      services.openssh.settings.PermitRootLogin = "prohibit-password";
      services.timesyncd.enable = false;
      # The documented timestamp is UTC even when the server's timezone is not.
      time.timeZone = "Europe/Amsterdam";
      boot.initrd.network.ssh.enable = false;
      networking.useDHCP = false;
      virtualisation = {
        memorySize = 2048;
        cores = 2;
        podman.enable = false;
      };
      services.fail2ban.enable = false;
      hardware.enableRedistributableFirmware = false;

      systemd.tmpfiles.rules = [
        "d /root/.ssh 0700 root root -"
        "C /root/.ssh/permanent 0600 root root - ${keys.snakeOilPrivateKey}"
        "C /root/.ssh/temporary 0600 root root - ${keys.snakeOilEd25519PrivateKey}"
      ];
      programs.ssh = {
        systemd-ssh-proxy.enable = false;
        extraConfig = ''
          Host permanent temporary
            HostName localhost
            User root
            IdentityFile /root/.ssh/%n
            IdentitiesOnly yes
            BatchMode yes
            StdinNull yes
            StrictHostKeyChecking accept-new
            ConnectTimeout 5
            ControlMaster no
            ControlPath none
        '';
      };
    };
  };
}

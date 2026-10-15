{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.microvmGuest.deployment;
  openssh = config.services.openssh;
  authorizedKeys = pkgs.writeText "idr-microvm-deployment-authorized-keys" (
    lib.concatStringsSep "\n" cfg.authorizedKeys + "\n"
  );
  sshdConfig = pkgs.writeText "idr-microvm-deployment-sshd.conf" ''
    ${lib.concatMapStringsSep "\n" (key: "HostKey ${key.path}") openssh.hostKeys}
    AuthorizedKeysFile /etc/ssh/idr-microvm-deployment-authorized-keys
    AllowUsers root
    PermitRootLogin prohibit-password
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    UsePAM yes
    PAMServiceName idr-microvm-deployment
    DisableForwarding yes
    PermitUserRC no
    UseDNS no
    Subsystem sftp internal-sftp
  '';
  validationPackage =
    if pkgs.stdenv.buildPlatform == pkgs.stdenv.hostPlatform
    then openssh.package
    else pkgs.buildPackages.openssh;
in {
  options.idr.microvmGuest.deployment = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Allow the MicroVM host to deploy or roll back this guest through a
        dedicated SSH service on VSOCK port 22, independently of guest networking.

        To disable it, first disable automatic guest deployment on the host,
        then deploy this guest change through ordinary network SSH or another
        connection. Management deployment requires this service to confirm updates.
      '';
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.singleLineStr;
      default = builtins.filter (key: key != null) (
        map (machine: let
          file = machine.config.idr.preset.base.defaultSopsFile or null;
          secrets = lib.optionalAttrs (file != null && lib.hasSuffix ".json" file) (lib.importJSON file);
        in
          secrets.ssh_host_ed25519_key_pub_unencrypted or null)
        config.idr.preset.base.sopsRecipientMachines
      );
      defaultText = lib.literalExpression "public SSH host keys of idr.preset.base.sopsRecipientMachines";
      description = ''
        Host public keys allowed to access the guest's root account through the
        management socket. Ordinary network SSH authorized keys do not grant
        management access. An empty list denies all management logins.
      '';
    };
  };

  config = lib.mkIf (config.idr.microvmGuest.enable && cfg.enable) {
    boot.kernelModules = ["vmw_vsock_virtio_transport"];

    # As with NixOS's authorized_keys.d files, copy the key file into /etc.
    # StrictModes rejects the group-writable /nix/store ancestor of a symlink.
    environment.etc."ssh/idr-microvm-deployment-authorized-keys" = {
      source = authorizedKeys;
      mode = "0444";
    };

    # Management SSH must also work when the ordinary network daemon is disabled.
    users.users.sshd = {
      isSystemUser = true;
      group = "sshd";
      description = "SSH privilege separation user";
    };
    users.groups.sshd = {};
    security.pam.services.idr-microvm-deployment = {
      startSession = true;
      unixAuth = false;
    };

    systemd.sockets.idr-microvm-deployment = {
      description = "MicroVM management SSH socket";
      wantedBy = ["sockets.target"];
      socketConfig = {
        ListenStream = "vsock::22";
        Accept = true;
        TriggerLimitIntervalSec = 0;
      };
    };

    systemd.services."idr-microvm-deployment@" = {
      description = "MicroVM management SSH connection";
      after = lib.optional openssh.generateHostKeys "sshd-keygen.service";
      wants = lib.optional openssh.generateHostKeys "sshd-keygen.service";
      # A changed template applies to new connections; keep the deployment's
      # existing inetd session alive until activation and confirmation finish.
      restartIfChanged = false;
      stopIfChanged = false;
      path = [openssh.package];
      environment.LD_LIBRARY_PATH = config.system.nssModules.path;
      # Reuse IDR's generation-specific key check even when network SSH is off.
      preStart = config.system.preSwitchChecks.idr-ssh-host-keys or "";
      serviceConfig = {
        ExecStart = "-${lib.getExe' openssh.package "sshd"} -i -D -f ${sshdConfig}";
        KillMode = "process";
        StandardInput = "socket";
        StandardError = "journal";
      };
    };

    system.checks = [
      (pkgs.runCommand "check-idr-microvm-deployment-sshd-config" {
          nativeBuildInputs = [validationPackage];
        } ''
          sshd -G -T -f ${sshdConfig} > /dev/null
          touch "$out"
        '')
    ];
  };
}

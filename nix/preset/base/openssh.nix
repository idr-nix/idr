top: moduleArgs @ {
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
  secrets = lib.optionalAttrs (cfg.base.defaultSopsFile != null) (lib.importJSON cfg.base.defaultSopsFile);
  publicKey = name:
    if secrets ? "${name}_pub_unencrypted"
    then lib.concatStringsSep " " (lib.take 2 (lib.splitString " " secrets."${name}_pub_unencrypted"))
    else null;
  # Keep each generation's host key available for rollback.
  keyPath = name: let
    version = lib.optionalString (secrets ? "${name}_pub_unencrypted") "idr/${builtins.hashString "sha256" (publicKey name)}/";
  in "${lib.optionalString cfg.impermanence.enable cfg.impermanence.persistDir}/etc/ssh/${version}${name}";
  hostKeyNames =
    ["ssh_host_ed25519_key"]
    ++ lib.optional config.boot.initrd.network.ssh.enable "initrd_ssh_host_ed25519_key";
  stagedKeys = builtins.filter (name: secrets ? ${name}) hostKeyNames;
  checkHostKeys = pkgs.writers.writeNu "idr-check-ssh-host-keys" ''
    def main [...args: string] {
      for key in ${builtins.toJSON (map (name: {
        path = keyPath name;
        publicKey = publicKey name;
      })
      stagedKeys)} {
        let result = ^${lib.getExe' pkgs.openssh "ssh-keygen"} -y -P "" -f $key.path | complete
        let public_key = $result.stdout | str trim | split row " " | first 2 | str join " "
        if $result.exit_code != 0 or ($key.publicKey != null and $public_key != $key.publicKey) {
          error make {msg: $"SSH host key ($key.path) is missing or does not match this generation; run idr-copy-extra-files before deploying."}
        }
      }
    }
  '';
  machine = "${config.networking.hostName}-${cfg.base.id}";
  members = lib.filterAttrs (_: member: member ? sshAccess.${machine}) top.idr-lib.team;
  grants = lib.mapAttrsToList (_: member:
    ({expiresAt ? null}: {
      inherit (member) sshPublicKey;
      inherit expiresAt;
    })
    member.sshAccess.${machine})
  members;
  sshKeys = map (grant:
    lib.optionalString (grant.expiresAt != null) ''expiry-time="${lib.replaceStrings ["-" ":" "T"] ["" "" ""] grant.expiresAt}" ''
    + grant.sshPublicKey)
  grants;
  expiries = builtins.filter (expiry: expiry != null) (map (grant: grant.expiresAt) grants);
  checkExpiryDates =
    pkgs.buildPackages.writers.writeNu "idr-ssh-expiry-dates" {
      check = "${lib.getExe pkgs.buildPackages.nushell} --no-config-file";
    } ''
      for expiry in ${builtins.toJSON expiries} {
        let parsed = $expiry | into datetime --format "%Y-%m-%dT%H:%M:%SZ" --timezone UTC
        if (($expiry | str length) != 20
            or ($parsed | format date "%Y-%m-%dT%H:%M:%SZ") != $expiry
            or ($parsed | format date "%S") == "60"
            or $parsed <= 1970-01-01T00:00:00Z) {
          error make {msg: $"Invalid SSH expiry date: ($expiry)"}
        }
      }
    '';
in {
  options.idr.preset.base = {
  };

  config = lib.mkIf cfg.base.enable (lib.mkMerge [
    # openssh
    (lib.mkIf (!config.boot.isContainer) {
      users.users.root.openssh.authorizedKeys.keyFiles = [
        (builtins.toFile "root-authorized-keys" (lib.concatStringsSep "\n" sshKeys))
      ];
      system.checks = lib.optional (expiries != []) checkExpiryDates;
      system.preSwitchChecks.idr-ssh-host-keys = lib.mkIf (stagedKeys != []) "${checkHostKeys}";

      idr.preset.base.postFormatFiles = lib.listToAttrs (map (name: lib.nameValuePair (keyPath name) {key = name;}) stagedKeys);

      # A missing staged key must not be replaced with an unrelated generated key.
      systemd.services.sshd-keygen.preStart = lib.mkIf (config.services.openssh.enable && stagedKeys != []) "${checkHostKeys}";

      boot.initrd.network.ssh = {
        enable = lib.mkDefault true;
        hostKeys = lib.mkDefault [(keyPath "initrd_ssh_host_ed25519_key")];
      };
      boot.initrd.systemd.users.root.shell = lib.mkIf config.boot.initrd.network.ssh.enable "/bin/systemd-tty-ask-password-agent";

      services.openssh = {
        enable = lib.mkDefault true;
        openFirewall = lib.mkDefault true;
        settings = {
          PrintMotd = lib.mkDefault true;
          KbdInteractiveAuthentication = lib.mkDefault false;
          PasswordAuthentication = lib.mkDefault false;
        };
        hostKeys = [
          {
            path = keyPath "ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
      };
    })
  ]);
}

top: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.preset;
  diskKey = cfg.base.preFormatFiles."/disk-key.txt" or null;
  secrets = lib.optionalAttrs (diskKey != null) (lib.importJSON diskKey.sopsFile);
  luksDevices = lib.collect (device: (device.type or null) == "luks") (
    # Disko's internal attributes include references back to parent devices.
    lib.filterAttrsRecursive (name: _: !lib.hasPrefix "_" name) config.disko.devices
  );
  devices =
    map (disk: let
      device = config.boot.initrd.luks.devices.${disk.name};
    in {
      inherit (device) device header;
    }) (builtins.filter
      (device: device.initrdUnlock && device.passwordFile == diskKey.path)
      luksDevices);
  enabled = cfg.base.enable && !config.boot.isContainer && diskKey != null && secrets ? ${diskKey.key};
  directory = "/run/idr-disk-keys";
  keyHash = secrets."${diskKey.key}_hash_unencrypted" or null;
  recoveryManifest =
    (import "${top.inputs.sops-nix}/modules/sops/manifest-for.nix" {
      inherit (pkgs) writeTextFile;
      inherit lib;
      cfg = config.sops;
    }) "-idr-disk-key-recovery" {
      idr-disk-key =
        config.sops.secrets.idr-disk-key
        // {
          sopsFile = builtins.path {
            path = config.sops.secrets.idr-disk-key.sopsFile;
            name = "idr-disk-key-recovery.enc.json";
          };
          path = "%r/recovery/secrets/idr-disk-key";
          restartUnits = [];
          reloadUnits = [];
        };
    } {} {
      secretsMountPoint = "%r/recovery/secrets.d";
      symlinkPath = "%r/recovery/secrets";
      keepGenerations = 1;
      ageKeyFile = null;
      sshKeyPaths = [];
      gnupgHome = null;
      placeholderBySecretName = {};
      userMode = true;
      logging = {
        keyImport = false;
        secretChanges = false;
      };
    };
  recoveryBundle = pkgs.writers.writeJSON "idr-disk-key-recovery.json" {
    inherit keyHash;
    manifest = recoveryManifest;
    installer = lib.getExe' config.sops.package "sops-install-secrets";
  };
  manifest = pkgs.writers.writeJSON "idr-disk-keys.json" {
    inherit devices directory keyHash;
    keyFile = config.sops.secrets.idr-disk-key.path;
    recovery = {
      bundle = recoveryBundle;
      current = "${lib.optionalString cfg.impermanence.enable cfg.impermanence.persistDir}/var/lib/idr/disk-key-recovery/current";
    };
  };
  cleanupNu = pkgs.nushell.override {
    additionalFeatures = features: features ++ ["ctrlc/termination"];
  };
  applyDiskKeys = pkgs.writers.makeScriptWriter {
    interpreter = "${lib.getExe cleanupNu} --no-config-file";
    makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.cryptsetup config.nix.package pkgs.coreutils])];
  } "/bin/idr-apply-disk-keys" (builtins.readFile ./key-rotation.nu);
  command = "${lib.getExe' pkgs.util-linux "flock"} ${directory}/lock ${lib.getExe applyDiskKeys}";
  revokeDiskKeys = pkgs.writers.writeNuBin "idr-revoke-old-disk-keys" ''
    def main [] {
      exec ${command} revoke ${manifest}
    }
  '';
in {
  config = lib.mkIf enabled {
    environment.systemPackages = [revokeDiskKeys];

    sops.secrets.idr-disk-key = {
      inherit (diskKey) sopsFile key;
      format = "json";
      mode = "0400";
    };

    systemd.services.idr-disk-keys = {
      description = "Enroll the disk key provided by SOPS";
      wantedBy = ["sysinit.target"];
      requiredBy = ["sysinit-reactivation.target"];
      before = ["sysinit.target" "sysinit-reactivation.target"];
      partOf = ["sysinit-reactivation.target"];
      after = ["local-fs.target"] ++ lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
      requires = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
      restartTriggers = [diskKey.sopsFile];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "idr-disk-keys";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = true;
        UMask = "0077";
        ExecStart = "${command} prepare ${manifest}";
      };
    };
  };
}

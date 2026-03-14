top: moduleArgs @ {
  config,
  options,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
in {
  options.idr.preset.impermanence = {
    enable = lib.mkOption {
      description = ''
        It works when using from start, for example when installing system via nixos-anywhere,
          and in consequent deployments.

        Can be integrated to existing systems too, but in that case you need to manually (1) copy files to `persistDir`,
          (2) deploy via `nixos-rebuild boot`, (3) reboot.
      '';
      type = lib.types.bool;
      default = cfg.impermanence.rootDataset != null;
    };
    persistDir = lib.mkOption {
      description = ''
        Directory where persistent files and directories are stored across reboots.
      '';
      type = lib.types.path;
      default = "/persist";
    };
    rootDataset = lib.mkOption {
      description = ''
        ZFS dataset used as the root filesystem, rolled back on each boot for impermanence.
      '';
      type = with lib.types; nullOr str;
      default = null;
      example = "p1/local/root";
    };
  };

  config = lib.mkIf cfg.impermanence.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = options ? disko;
          message = "disko module must be imported.";
        }
        {
          assertion = options ? environment.persistence;
          message = "impermanence module must be imported.";
        }
        {
          assertion = cfg.impermanence.rootDataset != null;
          message = "idr.preset.impermanence.enable requires idr.preset.impermanence.rootDataset to be set.";
        }
      ];
    }

    (lib.optionalAttrs (options ? disko && options ? environment.persistence) {
      environment.persistence.${cfg.impermanence.persistDir} = {
        hideMounts = true;
        directories = [
          "/var/log"
          "/var/lib/nixos"
          "/var/lib/systemd/coredump"
          "/var/lib/containers"
        ];
        files = [
          "/etc/machine-id"
        ];
      };

      fileSystems.${cfg.impermanence.persistDir}.neededForBoot = true;

      virtualisation.vmVariantWithDisko.virtualisation.fileSystems = {
        "${cfg.impermanence.persistDir}" = lib.mkForce config.fileSystems."${cfg.impermanence.persistDir}";
      };

      boot.initrd.systemd.enable = true;
      boot.initrd.systemd.extraBin = {
        "chattr" = "${pkgs.e2fsprogs}/bin/chattr";
        "jq" = "${pkgs.jq}/bin/jq";
      };
      boot.initrd.systemd.services.initrd-rollback-root = {
        after = ["zfs-import.target"];
        before = ["sysroot.mount"];
        description = "Rollback root fs";
        path = with pkgs; [
          config.boot.zfs.package
          findutils
          systemd
          e2fsprogs
          coreutils
          jq
          util-linuxMinimal
        ];
        serviceConfig.Type = "oneshot";
        unitConfig.DefaultDependencies = "no";
        wantedBy = ["initrd.target"];
        script = ''
          set -o pipefail
          root_dataset=${lib.escapeShellArg cfg.impermanence.rootDataset}
          if zfs list "$root_dataset"; then
            if zfs list -t snapshot "$root_dataset@blank"; then
              zfs rollback -r "$root_dataset@blank"
            else
              # Create empty snapshot & reboot
              properties=$(zfs get -jp -s local,received all "$root_dataset")
              altroot=$(zpool get -H -o value altroot "''${root_dataset%%/*}")
              temporary_dataset="$root_dataset-impermanence-tmp"
              temporary_mount=/run/idr-impermanence-root

              if zfs list -t snapshot "$root_dataset@impermanence-tmp"; then
                zfs destroy -R "$root_dataset@impermanence-tmp"
              fi
              zfs snapshot "$root_dataset@impermanence-tmp"
              zfs clone -u "$root_dataset@impermanence-tmp" "$temporary_dataset"
              mount_options=rw
              if [[ $(zfs get -H -o value mountpoint "$temporary_dataset") != legacy ]]; then
                mount_options+=,zfsutil
              fi
              mkdir -p "$temporary_mount"
              mount -t zfs -o "$mount_options" "$temporary_dataset" "$temporary_mount"
              find "$temporary_mount" -type "f,d" -exec chattr -i {} \;
              find "$temporary_mount" -mindepth 1 -delete
              umount "$temporary_mount"
              rmdir "$temporary_mount"

              # Promotion preserves keylocation; the count properties are read-only.
              jq -j --arg altroot "$altroot" '
                .datasets[].properties
                | del(.keylocation, .filesystem_count, .snapshot_count)
                | to_entries[]
                | if .key == "mountpoint" and (.value.value | startswith("/"))
                    and $altroot != "-" and $altroot != "/"
                  then .value.value |= (ltrimstr($altroot) | if . == "" then "/" else . end)
                  else . end
                | "\(.key)=\(.value.value)\u0000"
              ' <<< "$properties" | while IFS= read -r -d "" property; do
                zfs set -u "$property" "$temporary_dataset"
              done

              zfs promote "$temporary_dataset"
              zfs snapshot "$temporary_dataset@blank"
              zfs rename -u "$root_dataset" "$temporary_dataset-legacy"
              zfs rename -u "$temporary_dataset" "$root_dataset"
              zfs destroy -R "$temporary_dataset-legacy"
              zfs destroy -R "$root_dataset@impermanence-tmp"
              systemctl reboot
            fi
          fi
        '';
      };
    })
  ]);
}

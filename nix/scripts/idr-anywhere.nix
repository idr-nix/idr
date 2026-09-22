{expectedDisks, ...} @ args: let
  inherit (import ./idr-target.nix (builtins.removeAttrs args ["expectedDisks"])) meta pkgs profile;
  disks = map (disk: disk.path) (builtins.attrValues meta.disko.disks);
  diskoScript = pkgs.writers.writeNu "idr-disko" ''
    def main [] {
      ${pkgs.lib.optionalString ((meta.disko.hostId or null) != null) ''
      do --capture-errors {
        ^${pkgs.coreutils}/bin/install -m 0644 -- /run/idr-anywhere/hostid /etc/hostid
      }
    ''}
      try {
        ^${meta.formatMount}/bin/disko-format-mount
        null
      } catch {|error|
        # Only retry ordinary command failures; signals must stop installation.
        if $error.exit_code? not-in 1..127 {
          error make $error.raw
        }
        print --stderr "Best-effort formatting failed; retrying with a full disk wipe."
        exec ${meta.diskoScript}
      }
    }
  '';
in
  assert pkgs.lib.assertMsg (builtins.sort builtins.lessThan disks == builtins.sort builtins.lessThan expectedDisks)
  "The configured installation disks changed after inspection. Rerun idr-anywhere to inspect and confirm the updated disk selection."; {
    pkgs.system = meta.system;
    nix.settings = meta.nixSettings;
    system.build = {
      inherit diskoScript;
      # Keep deploy-rs activation entrypoints in the first installed generation.
      toplevel = profile.path;
    };
  }

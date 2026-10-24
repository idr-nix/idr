{
  expectedDisks,
  diskoMode ? "disko",
  ...
} @ args: let
  inherit (import ./idr-target.nix (builtins.removeAttrs args ["expectedDisks" "diskoMode"])) meta pkgs profile;
  disks = map (disk: disk.path) (builtins.attrValues meta.disko.disks);
  prepareHostId = pkgs.lib.optionalString ((meta.disko.hostId or null) != null) ''
    do --capture-errors {
      ^${pkgs.coreutils}/bin/install -m 0644 -- /run/idr-anywhere/hostid /etc/hostid
    }
  '';
  mountScript = script:
    pkgs.writers.writeNu "idr-disko-mount" ''
      def main [] {
        ${prepareHostId}
        exec ${script}
      }
    '';
  diskoScript = pkgs.writers.writeNu "idr-disko" ''
    def main [] {
      ${prepareHostId}
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
  assert pkgs.lib.assertMsg (builtins.elem diskoMode ["disko" "mount"])
  "idr-anywhere supports diskoMode disko or mount.";
  assert pkgs.lib.assertMsg (builtins.sort builtins.lessThan disks == builtins.sort builtins.lessThan expectedDisks)
  "The configured installation disks changed after inspection. Rerun idr-anywhere to inspect and confirm the updated disk selection."; {
    pkgs.system = meta.system;
    nix.settings = meta.nixSettings;
    system.build =
      {
        # Keep deploy-rs activation entrypoints in the first installed generation.
        toplevel = profile.path;
      }
      // (
        if diskoMode == "mount"
        then {
          mountScript = mountScript meta.mountScript;
          mountScriptNoDeps = mountScript meta.mountScriptNoDeps;
        }
        else {inherit diskoScript;}
      );
  }

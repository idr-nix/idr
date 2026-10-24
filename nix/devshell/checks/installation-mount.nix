{pkgs}: let
  record = name:
    pkgs.writeShellScript name ''
      printf '%s\n' ${name} >> "$OPERATIONS"
      exit "''${${name}_STATUS:-0}"
    '';
  meta = {
    system = pkgs.stdenv.hostPlatform.system;
    nixSettings = {};
    disko.disks.root.path = "/dev/installation-test";
    mountScript = record "mount";
    mountScriptNoDeps = record "mountNoDeps";
    formatMount = pkgs.writeShellScriptBin "disko-format-mount" ''
      printf '%s\n' format >> "$OPERATIONS"
      exit "''${format_STATUS:-0}"
    '';
    diskoScript = record "wipe";
  };
  evaluate = arguments:
    import ../../scripts/idr-anywhere.nix ({
        expectedDisks = ["/dev/installation-test"];
        projectRoot = "/unused";
        node = "test-machine";
        flake = {
          inputs.nixpkgs = {
            inherit (pkgs) lib;
            legacyPackages.${pkgs.stdenv.hostPlatform.system} = pkgs;
          };
          deploy.nodes.test-machine.profiles.system.path.idr = {inherit meta;};
        };
      }
      // arguments);
  mounting = (evaluate {diskoMode = "mount";}).system.build;
  formatting = (evaluate {}).system.build;
  scripts = pkgs.writeText "installation-mount-scripts.json" (builtins.toJSON {
    inherit (mounting) mountScript mountScriptNoDeps;
    inherit (formatting) diskoScript;
  });
in
  assert !(mounting ? diskoScript);
  assert !(formatting ? mountScript);
    pkgs.runCommand "installation-mount" {
      nativeBuildInputs = with pkgs; [coreutils nushell python3];
      SCRIPT_SOURCE = ../../scripts;
      SCRIPT_PATHS = scripts;
    } ''
      python3 ${./fixtures/installation-mount.py}
      touch "$out"
    ''

{pkgs}: let
  record = name:
    pkgs.writers.writeNu name ''
      "${name}\n" | save --append $env.OPERATIONS
      exit ($env | get --optional ${name}_STATUS | default "0" | into int)
    '';
  meta = {
    system = pkgs.stdenv.hostPlatform.system;
    nixSettings = {};
    disko.disks.root.path = "/dev/installation-test";
    mountScript = record "mount";
    mountScriptNoDeps = record "mountNoDeps";
    formatMount = pkgs.writers.writeNuBin "disko-format-mount" ''
      "format\n" | save --append $env.OPERATIONS
      exit ($env.format_STATUS? | default "0" | into int)
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
      nativeBuildInputs = with pkgs; [coreutils nushell];
      SCRIPT_SOURCE = ../../scripts;
      SCRIPT_PATHS = scripts;
    } ''
      nu --no-config-file --no-std-lib --no-history ${./fixtures/installation-mount.nu}
      touch "$out"
    ''

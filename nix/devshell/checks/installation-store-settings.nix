{pkgs}: let
  nixos-anywhere = pkgs.callPackage ../../idr/deploy/nixos-anywhere-package.nix {};
  test = pkgs.writers.writeNu "installation-store-settings" ''
    for settings in [
      [--ssh-store-setting remote-program "nix-daemon%20--option%20require-sigs%20false"]
      [--ssh-store-setting remote-program "nix-daemon%20--option%20require-sigs%20false" --ssh-store-setting compress "true"]
    ] {
      # --help exercises the parser and exits before any target connection.
      let result = (
        ^${pkgs.lib.getExe nixos-anywhere}
          --target-host root@example.invalid
          ...$settings
          --ssh-port 2223
          --help
        | complete
      )
      if $result.exit_code != 0 or not ($result.stdout | str starts-with "Usage: nixos-anywhere") {
        error make {msg: $"Argument parsing failed: ($result.stdout)($result.stderr)"}
      }
    }
  '';
in
  pkgs.runCommand "installation-store-settings" {} ''
    ${test}
    touch "$out"
  ''

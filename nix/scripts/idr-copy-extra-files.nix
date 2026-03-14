args @ {...}: let
  inherit (import ./idr-target.nix args) pkgs;
in
  pkgs.writers.writeNuBin "idr-copy-extra-files-receiver" {
    makeWrapperArgs = ["--prefix" "PATH" ":" (pkgs.lib.makeBinPath [pkgs.coreutils])];
  } (builtins.readFile ./idr-copy-extra-files-receiver.nu)

{
  flake.preservedImport = "module";

  perSystem = {pkgs, ...}: {
    packages.existing = pkgs.writeText "existing-output" "kept\n";
  };
}

{
  pkgs,
  packages,
}:
# Separate main from the generated shebang so it does not appear in --help.
pkgs.writers.writeNuBin "idr-update-packages" {
  makeWrapperArgs = [
    "--set"
    "IDR_PACKAGES_FILE"
    (pkgs.writers.writeJSON "idr-packages.json" packages)
  ];
} ("\n" + builtins.readFile ../../scripts/idr-update-packages.nu)

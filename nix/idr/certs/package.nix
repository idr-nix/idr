{
  pkgs,
  certs,
}: let
  manifest = pkgs.writers.writeJSON "idr-certificates.json" certs;
in
  pkgs.writers.writeNuBin "idr-update-certs" {
    makeWrapperArgs = [
      "--set"
      "IDR_CERTS_FILE"
      manifest
      "--prefix"
      "PATH"
      ":"
      (pkgs.lib.makeBinPath [pkgs.lego pkgs.sops pkgs.gitMinimal pkgs.coreutils])
    ];
  } ''
    source ${../../scripts}/idr-update-certs.nu
  ''

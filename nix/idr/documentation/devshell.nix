{nixdocPackage}: {pkgs, ...}: {
  packages = [
    pkgs.mdbook
    nixdocPackage
    (pkgs.writeShellApplication {
      name = "idr-generate-docs";
      text = ''
        exec "$IDR_BACKGROUND_BUILD" generate "$@"
      '';
    })
  ];
}

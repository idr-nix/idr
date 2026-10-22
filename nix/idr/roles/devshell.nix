_: {
  config,
  lib,
  pkgs,
  ...
}: let
  template = builtins.path {
    path = config.idr.templatesDir + "/role";
    name = "idr-role-template";
  };
  # Separate main from the generated shebang so it does not appear in --help.
  idr-mk-role = pkgs.writers.writeNuBin "idr-mk-role" {
    makeWrapperArgs = [
      "--set"
      "IDR_ROLE_TEMPLATE"
      template
      "--prefix"
      "PATH"
      ":"
      (lib.makeBinPath [pkgs.copier pkgs.coreutils pkgs.gitMinimal])
    ];
  } ("\n" + builtins.readFile ../../scripts/idr-mk-role.nu);
in {
  commands = [
    {
      name = "idr-mk-role";
      package = idr-mk-role;
      help = "Create a role scaffold";
    }
  ];
}

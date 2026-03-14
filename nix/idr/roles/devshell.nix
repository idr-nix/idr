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
  idr-mk-role =
    pkgs.writers.writeNuBin "idr-mk-role" {
      makeWrapperArgs = [
        "--set"
        "IDR_ROLE_TEMPLATE"
        template
        "--prefix"
        "PATH"
        ":"
        (lib.makeBinPath [pkgs.copier pkgs.coreutils pkgs.gitMinimal])
      ];
    } ''
      source ${../../scripts}/idr-mk-role.nu
    '';
in {
  commands = [
    {
      name = "idr-mk-role";
      package = idr-mk-role;
      help = "Create a role scaffold";
    }
  ];
}

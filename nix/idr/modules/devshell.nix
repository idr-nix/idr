_: {
  config,
  lib,
  pkgs,
  ...
}: let
  template = builtins.path {
    path = config.idr.templatesDir + "/module";
    name = "idr-module-template";
  };
  idr-mk-module =
    pkgs.writers.writeNuBin "idr-mk-module" {
      makeWrapperArgs = [
        "--set"
        "IDR_MODULE_TEMPLATE"
        template
        "--prefix"
        "PATH"
        ":"
        (lib.makeBinPath [pkgs.copier pkgs.coreutils pkgs.gitMinimal])
      ];
    } ''
      source ${../../scripts}/idr-mk-module.nu
    '';
in {
  commands = [
    {
      name = "idr-mk-module";
      package = idr-mk-module;
      help = "Create a reusable NixOS module scaffold";
    }
  ];
}

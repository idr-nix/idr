top: {
  inputs,
  lib,
  config,
  flake-parts-lib,
  ...
}: {
  imports = lib.attrValues (top.idr-lib.importFlakeModules ./. top);
}

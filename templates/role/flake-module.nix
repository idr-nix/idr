top: {lib, ...}: {
  imports = lib.attrValues (top.idr-lib.importFlakeModules ./. top);
}

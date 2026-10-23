top: {
  lib,
  pkgs,
  ...
}: {
  imports = [(lib.modules.importApply ./offline-startup.nix top)];

  idr.additionalPaths = [pkgs.redis pkgs.fzf (lib.getMan pkgs.fzf)];
}

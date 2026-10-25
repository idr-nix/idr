top: {
  lib,
  pkgs,
  ...
}: {
  idr.additionalPaths = [pkgs.redis pkgs.fzf (lib.getMan pkgs.fzf)];
}

top: moduleArgs @ {
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
  inherit (cfg.base) inputs;
in {
  options.idr.preset.base = {
  };

  config = lib.mkIf cfg.base.enable (lib.mkMerge [
    # Correctly display configuration revision in nixos-version
    (lib.mkIf (!config.boot.isContainer) {
      system.configurationRevision = toString (
        inputs.self.shortRev or inputs.self.dirtyShortRev or inputs.self.lastModified or "unknown"
      );

      nixpkgs.overlays =
        lib.optional (inputs ? nixpkgs)
        (let
          libVersionInfoOverlay = import "${inputs.nixpkgs}/lib/flake-version-info.nix" inputs.nixpkgs;
        in (final: prev: {
          # Ensure version info is properly populated.
          lib = prev.lib.extend libVersionInfoOverlay;
        }));
    })
  ]);
}

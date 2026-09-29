_: {
  lib,
  inputs,
  flake-parts-lib,
  ...
}: {
  options.perSystem = flake-parts-lib.mkPerSystemOption ({
    config,
    pkgs,
    system,
    ...
  }: let
    cfg = config.idr.nix-search-tv;
    optionDocs = config.idr.documentation.optionDocs;
    searchConfig = pkgs.callPackage ./config.nix {
      inherit inputs system;
      inherit (optionDocs) json-docs input-json-docs;
    };
  in {
    options.idr.nix-search-tv.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable local option search in the devshell, independently of HTML documentation.";
    };
    config = {
      checks.idr-option-generation = import ./checks/options.nix {inherit lib pkgs flake-parts-lib;};
      # Also expose option data through passthru for downstream IDR projects,
      # without making them evaluate or build the HTML book.
      packages.idr-nix-search-tv-config = searchConfig;
      devshells.default =
        lib.mkIf cfg.enable
        (lib.modules.importApply ./devshell.nix {inherit searchConfig;});
    };
  });
}

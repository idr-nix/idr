{
  idr-generate-docs,
  mk-docs,
}: {
  lib,
  pkgs,
  config,
  inputs,
  ...
}: let
  scripts = ../../scripts;
  idr-nix-search-tv = pkgs.writeShellApplication {
    name = "nix-search-tv";
    runtimeInputs = with pkgs; [nushell];
    text = ''
      exec nu ${scripts}/idr-nix-search-tv.nu "$@"
    '';
  };
in {
  packagesFrom = [
    mk-docs
  ];

  env = [
    {
      name = "IDR_NIX_SEARCH_TV_PATH";
      value = "${pkgs.nix-search-tv}/bin/nix-search-tv";
    }
    {
      name = "IDR_NIX_SEARCH_TV_CONFIG_PATH";
      value = "${mk-docs}/nix-search-tv.json";
    }
  ];

  commands = [
    {
      category = "documentation";
      name = "nix-search-tv";
      package = idr-nix-search-tv;
      help = "Fuzzy search for Nix options";
    }
  ];

  devshell.startup.idr-generate-docs = {
    text = ''
      mkdir -p "$PRJ_DATA_DIR"
      if [[ -w "$PRJ_ROOT" ]] &&
        [[ ! -d "$PRJ_ROOT/docs/generated" ||
          "$(readlink -f "$PRJ_DATA_DIR/idr-generate-docs")" != "$(readlink -f ${idr-generate-docs})" ]]; then
        rm -f "$PRJ_DATA_DIR/idr-generate-docs"
        (cd "$PRJ_ROOT" && ${idr-generate-docs}/bin/idr-generate-docs) &&
          ln -Tfs "${idr-generate-docs}" "$PRJ_DATA_DIR/idr-generate-docs"
      fi
    '';
  };
}

{searchConfig}: {pkgs, ...}: let
  scripts = ../../scripts;
  search = pkgs.writeShellApplication {
    name = "nix-search-tv";
    runtimeInputs = [pkgs.nushell];
    text = ''
      exec nu ${scripts}/idr-nix-search-tv.nu "$@"
    '';
  };
in {
  env = [
    {
      name = "IDR_NIX_SEARCH_TV_PATH";
      value = "${pkgs.nix-search-tv}/bin/nix-search-tv";
    }
    {
      name = "IDR_NIX_SEARCH_TV_CONFIG_PATH";
      value = "${searchConfig}";
    }
  ];
  commands = [
    {
      category = "documentation";
      name = "nix-search-tv";
      package = search;
      help = "Fuzzy search for Nix options";
    }
  ];
}

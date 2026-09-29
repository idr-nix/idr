{
  lib,
  writeText,
  json-docs,
  input-json-docs,
  inputs ? {},
  system,
}: let
  optionsFile = import ./indexes.nix {
    inherit lib json-docs input-json-docs inputs system;
  };
  config = writeText "nix-search-tv.json" (builtins.toJSON {
    cache_dir = "nix-search-tv";
    enable_waiting_message = false;
    experimental = {
      options_file = optionsFile;
      render_docs_indexes = {};
    };
    indexes = [];
    update_interval = "1s";
  });
  passthru = {inherit json-docs input-json-docs;};
  package = config.overrideAttrs {inherit passthru;};
in
  # writeText forces its text argument. Reading the option data of an input
  # must not generate that input's entire search config before we can dedupe it.
  lib.lazyDerivation {
    derivation = package;
    passthru =
      passthru
      // {
        inherit passthru;
        inherit (package) overrideAttrs;
      };
  }

{
  stdenv,
  mdbook,
  idr-generate-docs,
  json-docs,
  input-json-docs,
  writeText,
  src,
  assets ? [],
  lib,
  nix-gitignore,
  writeClosure,
  ...
}: let
  assetPaths = map (asset: lib.removePrefix "./" (lib.path.subpath.normalise asset)) assets;
  mkOptionsFile = {
    json-docs,
    input-json-docs,
    ...
  }:
    lib.foldl'
    (outer_acc: name: let
      inputs = mkOptionsFile input-json-docs.${name};
    in (
      lib.foldl'
      (acc: input_name:
        acc
        // lib.optionalAttrs (!(builtins.elem inputs.${input_name} (builtins.attrValues acc))) {
          "${name}:${input_name}" = inputs.${input_name};
        })
      outer_acc
      (lib.reverseList (builtins.attrNames inputs))
    ))
    json-docs
    (lib.reverseList (builtins.attrNames input-json-docs));

  options_file = mkOptionsFile {inherit json-docs input-json-docs;};

  nix-search-tv-config = writeText "nix-search-tv.json" (builtins.toJSON {
    cache_dir = "nix-search-tv";
    enable_waiting_message = false;
    experimental = {
      inherit options_file;
      render_docs_indexes = {};
    };
    indexes = [];
    update_interval = "1s";
  });
in
  stdenv.mkDerivation {
    src =
      nix-gitignore.gitignoreFilterSource
      (path: type: let
        relative = lib.removePrefix "${toString src}/" path;
      in
        type
        == "directory"
        || lib.hasSuffix ".md" path
        || builtins.elem relative ["book.toml" "book.toml.jinja"]
        || lib.any (asset: relative == asset || lib.hasPrefix "${asset}/" relative) assetPaths)
      [../../../.gitignore]
      src;
    nativeBuildInputs = [
      mdbook
      idr-generate-docs
    ];

    name = "mk-docs";
    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      if ! [[ -f book.toml ]] && [[ -f book.toml.jinja ]]; then
        cp book.toml.jinja book.toml
      fi

      idr-generate-docs

      mdbook build --dest-dir book

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      if [[ -f book/index.html ]]; then
        mkdir -p $out
        cp -Ta book $out/html
      else
        cp -Ta book $out
      fi
      cp -Ta docs $out/docs
      find . -path ./book -prune -o -path ./docs -prune -o \
        -type f -name '*.md' -exec cp --parents -t "$out" {} +

      ln -Tsf ${nix-search-tv-config} $out/nix-search-tv.json

      runHook postInstall
    '';

    passthru = {
      inherit json-docs input-json-docs;
    };
  }

{
  stdenv,
  mdbook,
  idr-generate-docs,
  json-docs,
  input-json-docs,
  src,
  assets ? [],
  lib,
  nix-gitignore,
  ...
}: let
  assetPaths = map (asset: lib.removePrefix "./" (lib.path.subpath.normalise asset)) assets;
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

      runHook postInstall
    '';

    passthru = {
      inherit json-docs input-json-docs;
    };
  }

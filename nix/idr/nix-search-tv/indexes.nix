{
  lib,
  json-docs,
  input-json-docs,
  inputs ? {},
  system,
}: let
  # Include the resolved dependency graph, not just the source path: input
  # overrides can change a flake's outputs. Cycles conservatively disable reuse.
  inputIdentity = ancestors: input: let
    source = toString input;
    children = lib.mapAttrs (_: input: inputIdentity (ancestors ++ [source]) input) (input.inputs or {});
  in
    if builtins.elem source ancestors
    then null
    else if lib.any (value: value == null) (builtins.attrValues children)
    then null
    else {
      inherit source;
      metadata = builtins.removeAttrs (input.sourceInfo or {}) ["outPath"];
      inputs = children;
    };
  nixpkgsKey = source:
    if !(source ? lib.nixosSystem)
    then null
    else let
      identity = inputIdentity [] source;
    in
      if identity == null
      then null
      else
        builtins.hashString "sha256"
        (builtins.unsafeDiscardStringContext (builtins.toJSON {inherit identity system;}));

  # Memoize Nixpkgs indexes before forcing their paths. Comparing outPaths only
  # afterwards repeats NixOS option evaluation for every occurrence in the graph.
  # The same Nixpkgs input uses the same fixed modules, without specialArgs.
  # Other module indexes keep their existing per-provider evaluation context.
  collectIndexes = source: {
    json-docs,
    input-json-docs,
    ...
  }: cache: let
    key =
      if json-docs ? "(nixos)"
      then nixpkgsKey source
      else null;
    value =
      if key != null && cache ? ${key}
      then cache.${key}
      else json-docs."(nixos)";
    ownDocs = json-docs // lib.optionalAttrs (key != null) {"(nixos)" = value;};
    initial = {
      docs = ownDocs;
      indexes = builtins.attrValues ownDocs;
      cache = cache // lib.optionalAttrs (key != null) {${key} = value;};
    };
  in
    lib.foldl'
    (outer: name: let
      child = collectIndexes ((source.inputs or {}).${name} or {}) input-json-docs.${name} outer.cache;
    in {
      inherit (child) cache;
      indexes = outer.indexes ++ child.indexes;
      docs =
        lib.foldl'
        (acc: inputName:
          acc
          // lib.optionalAttrs (!(builtins.elem child.docs.${inputName} (builtins.attrValues acc))) {
            "${name}:${inputName}" = child.docs.${inputName};
          })
        outer.docs
        (lib.reverseList (builtins.attrNames child.docs));
    })
    initial
    (lib.reverseList (builtins.attrNames input-json-docs));
  collected = collectIndexes {inherit inputs;} {inherit json-docs input-json-docs;} {};
  # Schedule indexes before path-based deduplication forces their evaluation.
  # Stock Nix keeps evaluating them on demand.
  parallel = builtins.parallel or (_: result: result);
in
  parallel collected.indexes collected.docs

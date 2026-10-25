{
  lib,
  pkgs,
  idr,
}: let
  serialize = ancestors: path: input: let
    previous =
      lib.findFirst (ancestor:
        ancestor.input.outPath
        == input.outPath
        && (ancestor.input.sourceInfo or ancestor.input) == (input.sourceInfo or input)
        && builtins.elem (input.inputs or {}) [(ancestor.input.inputs or {})])
      null
      ancestors;
  in
    if previous != null
    then {ref = previous.path;}
    else {
      source = input.outPath;
      info = builtins.removeAttrs (input.sourceInfo or input) ["outPath"];
      flake = input ? inputs;
      inputs = lib.mapAttrs (name: serialize (ancestors ++ [{inherit input path;}]) (path ++ [name])) (input.inputs or {});
    };
  inputs = pkgs.writeText "idr-offline-inputs.json" (builtins.toJSON (serialize [] [] idr));
  flake = pkgs.writeText "idr-offline-flake.nix" ''
    {
      outputs = { self }: let
        graph = builtins.fromJSON (builtins.readFile ./inputs.json);
        sourceKey = node: builtins.hashString "sha256" (builtins.toJSON [ node.source node.info.narHash ]);
        collectSources = node: if node ? ref then {} else
          builtins.foldl' (sources: child: sources // collectSources child) {
            "''${sourceKey node}" = builtins.fetchTree {
              type = "path";
              path = node.source;
              inherit (node.info) narHash;
            };
          } (builtins.attrValues node.inputs);
        # Shared source accessors keep declaration paths identical with lazy trees.
        sources = collectSources graph;
        load = node: if node ? ref then
          builtins.foldl' (input: name: input.inputs.''${name}) root node.ref
        else let
          source = sources.''${sourceKey node};
          sourceInfo = node.info // { outPath = source.outPath; };
          inputs = builtins.mapAttrs (_: load) node.inputs;
          outputs = (import (source.outPath + "/flake.nix")).outputs (inputs // { self = result; });
          result = if node.flake then outputs // sourceInfo // {
            inherit inputs outputs sourceInfo;
            _type = "flake";
          } else sourceInfo;
        in result;
        root = load graph;
      in { packages = root.packages; };
    }
  '';
in
  pkgs.runCommand "idr-offline-source" {} ''
    mkdir -p "$out"
    cp ${inputs} "$out/inputs.json"
    cp ${flake} "$out/flake.nix"
  ''

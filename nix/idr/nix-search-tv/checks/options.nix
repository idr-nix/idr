{
  lib,
  pkgs,
  flake-parts-lib,
}: let
  searchModule = import ../flake-module.nix {} {
    inherit lib flake-parts-lib;
    inputs = {};
  };
  documentedOptions = searchModule.options.perSystem.type.getSubOptions ["perSystem"];
  documentedSearch =
    (pkgs.nixosOptionsDoc {
      options = documentedOptions;
      warningsAreErrors = false;
    }).optionsNix;
  # Compare public documentation data, including suboptions whose parent was
  # declared elsewhere and the module system's visibility modes.
  child = {
    _file = "/owned/child.nix";
    options.fromChild = lib.mkOption {
      type = lib.types.str;
      default = "child default";
      description = "Child description";
    };
  };
  nested = lib.types.attrsOf (lib.types.submodule child);
  options =
    (lib.evalModules {
      modules = [
        {
          _file = "/foreign/options.nix";
          options = {
            foreign = lib.mkOption {
              type = lib.types.str;
              default = "foreign";
            };
            parent = lib.mkOption {
              type = nested;
              default = {};
            };
            transparent = lib.mkOption {
              type = nested;
              visible = "transparent";
            };
            shallow = lib.mkOption {
              type = nested;
              visible = "shallow";
            };
            hidden = lib.mkOption {
              type = nested;
              visible = false;
            };
          };
        }
        {
          _file = "/owned/options.nix";
          options.direct = lib.mkOption {
            type = lib.types.int;
            default = 42;
            description = "Owned option";
          };
        }
      ];
    }).options;
  doc = options:
    (pkgs.nixosOptionsDoc {
      inherit options;
      warningsAreErrors = false;
      transformOptions = option:
        option
        // {
          visible = option.visible && lib.any (file: lib.hasPrefix "/owned/" (toString file)) option.declarations;
        };
    }).optionsNix;
  before = doc options;
  after =
    (pkgs.nixosOptionsDoc {
      warningsAreErrors = false;
      options = import ../../documentation/source-options.nix {
        inherit lib options;
        source = "/owned";
      };
    }).optionsNix;

  input = version: dependency: {
    outPath = "/inputs/${version}";
    sourceInfo.rev = version;
    lib.nixosSystem = _: throw "Index collection evaluated NixOS";
    inputs.dependency.outPath = dependency;
  };
  stable = input "stable" "/dependency/one";
  overridden = input "stable" "/dependency/two";
  newer = input "newer" "/dependency/one";
  cyclic = {
    outPath = "/cycle";
    lib.nixosSystem = _: throw "Index collection evaluated NixOS";
    inputs.self = cyclic;
  };
  leaf = path: {
    json-docs."(nixos)" = path;
    input-json-docs = {};
  };
  indexes = import ../indexes.nix {
    inherit lib;
    system = "x86_64-linux";
    json-docs = {
      "(flake)" = "/project.json";
      "(generic)" = "/project.json";
    };
    inputs = {
      z = stable;
      y = overridden;
      x = newer;
      w = cyclic;
      v = cyclic;
      provider = {
        outPath = "/provider";
        inputs.alias = stable;
      };
    };
    input-json-docs = {
      z = leaf "/stable.json";
      y = leaf "/override.json";
      x = leaf "/newer.json";
      w = leaf "/cycle-one.json";
      v = leaf "/cycle-two.json";
      provider = {
        json-docs = {};
        input-json-docs.alias = leaf (throw "Duplicate Nixpkgs option generation was forced");
      };
    };
  };
  metadataOnly = import ../config.nix {
    inherit lib;
    system = "x86_64-linux";
    writeText = _: _: throw "Reading passthru generated a search config";
    json-docs."(nixos)" = "/index.json";
    input-json-docs = throw "Reading passthru traversed the dependency indexes";
  };
in
  assert documentedSearch ? "perSystem.idr.nix-search-tv.enable";
  assert metadataOnly.passthru.json-docs == {"(nixos)" = "/index.json";};
  assert builtins.toJSON before == builtins.toJSON after;
  assert after ? "parent.<name>.fromChild";
  assert after ? "transparent.<name>.fromChild";
  assert !(after ? "shallow.<name>.fromChild");
  assert !(after ? "hidden.<name>.fromChild");
  assert indexes
  == {
    "(flake)" = "/project.json";
    "(generic)" = "/project.json";
    "z:(nixos)" = "/stable.json";
    "y:(nixos)" = "/override.json";
    "x:(nixos)" = "/newer.json";
    "w:(nixos)" = "/cycle-one.json";
    "v:(nixos)" = "/cycle-two.json";
  };
    pkgs.runCommand "idr-option-generation" {} ''touch $out''

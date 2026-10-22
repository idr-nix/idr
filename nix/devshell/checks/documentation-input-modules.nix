top: {lib, ...}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    moduleClasses = ["nixos" "flake" "devshell" "homeManager" "darwin" "service" "generic" "nixosTest"];
    optionModule = name: {lib, ...}: {
      options.documentationInput.${name} = lib.mkOption {
        type = lib.types.str;
        default = "${name} default";
        example = "${name} example";
        description = "Documentation input ${name}.";
      };
    };
    source = name: {
      outPath = toString top.self;
      narHash = "documentation-fixture-${name}";
    };
    fixture = {
      providers,
      projectModules ? {project = optionModule "project";},
    }: let
      fixtureSelf =
        source "project"
        // {
          modules = lib.genAttrs moduleClasses (_: {}) // {generic = projectModules;};
        };
      outputs =
        top.inputs.flake-parts.lib.mkFlake {
          inputs =
            {
              self = fixtureSelf;
              inherit (top.inputs) nixpkgs;
            }
            // lib.mapAttrs (name: provider: source name // provider) providers;
        } ({withSystem, ...}: {
          imports = [
            top.inputs.devshell.flakeModule
            (lib.modules.importApply ../../idr/documentation/flake-module.nix top)
          ];
          systems = [system];
          perSystem = {
            _module.args.pkgs = pkgs;
            idr.documentation.enable = false;
          };
          flake.optionDocs = withSystem system ({config, ...}: config.idr.documentation.optionDocs);
        });
    in
      outputs.optionDocs;
    docs = fixture {
      providers = {
        catalog = {
          nixosModule = throw "obsolete singular default";
          nixosModules = {
            default = throw "obsolete named default";
            removed = throw "removed module export";
            legacy = optionModule "legacy";
            overridden = throw "superseded module export";
          };
          modules.nixos = {
            modern = optionModule "modern";
            overridden = optionModule "overridden";
            unavailableValues = {lib, ...}: {
              options.documentationInput = {
                unavailableDefault = lib.mkOption {
                  type = lib.types.attrs;
                  default = {nested.value = throw "unavailable default";};
                  description = "An input option with an unavailable default.";
                };
                unavailableDefaultText = lib.mkOption {
                  type = lib.types.str;
                  defaultText = {
                    _type = "literalExpression";
                    text = throw "unavailable default text";
                  };
                  description = "An input option with unavailable default text.";
                };
                unavailableExample = lib.mkOption {
                  type = lib.types.attrs;
                  default = {};
                  example = {nested.value = throw "unavailable example";};
                  description = "An input option with an unavailable example.";
                };
                hidden = lib.mkOption {
                  type = lib.types.str;
                  visible = false;
                  default = {}.missing;
                };
                internal = lib.mkOption {
                  type = lib.types.str;
                  internal = true;
                  default = {}.missing;
                };
              };
            };
          };
        };
        defaultOnly.nixosModule = optionModule "defaultOnly";
        removedOnly.nixosModules.removed = throw "removed only export";
      };
    };
    brokenInput = fixture {
      providers.broken.nixosModules.module = {...}: throw "broken input module body";
    };
    brokenProject = fixture {
      providers = {};
      projectModules.broken = throw "broken project module";
    };
    brokenProjectDefault = fixture {
      providers = {};
      projectModules.broken = {lib, ...}: {
        options.broken = lib.mkOption {
          type = lib.types.str;
          default = throw "broken project default";
          description = "A project option with an invalid default.";
        };
      };
    };
    cannotEvaluate = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  in {
    checks.documentation-input-modules = assert lib.assertMsg (cannotEvaluate brokenInput.input-json-docs.broken.json-docs."(nixos)") "Input module body errors must fail documentation evaluation";
    assert lib.assertMsg (cannotEvaluate brokenProject.json-docs."(generic)") "Project module errors must fail documentation evaluation";
    assert lib.assertMsg (cannotEvaluate brokenProjectDefault.json-docs."(generic)") "Project option default errors must fail documentation evaluation";
      pkgs.runCommand "documentation-input-modules" {
        nativeBuildInputs = [pkgs.python3];
        projectDocs = docs.json-docs."(generic)";
        catalogDocs = docs.input-json-docs.catalog.json-docs."(nixos)";
        defaultDocs = docs.input-json-docs.defaultOnly.json-docs."(nixos)";
        removedDocs = docs.input-json-docs.removedOnly.json-docs."(nixos)";
      } ''
        python3 <<'PY'
        import json
        import os

        def read(name):
            with open(os.environ[name]) as source:
                return json.load(source)

        project = read("projectDocs")
        assert "documentationInput.project" in project, project
        catalog = read("catalogDocs")
        for name in ["legacy", "modern", "overridden"]:
            option = catalog[f"documentationInput.{name}"]
            assert name + " default" in option["default"]["text"], option
            assert name + " example" in option["example"]["text"], option
            assert f"Documentation input {name}." in option["description"], option
        for name, field in [
            ("unavailableDefault", "default"),
            ("unavailableDefaultText", "default"),
            ("unavailableExample", "example"),
        ]:
            option = catalog[f"documentationInput.{name}"]
            assert field not in option, option
            assert option["description"] and option["type"], option
        assert "default" in catalog["documentationInput.unavailableExample"], catalog
        assert "documentationInput.hidden" not in catalog, catalog
        assert "documentationInput.internal" not in catalog, catalog
        assert "documentationInput.defaultOnly" in read("defaultDocs")
        assert read("removedDocs") == {}
        PY
        touch "$out"
      '';
  };
}

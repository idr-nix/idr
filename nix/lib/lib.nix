top @ {lib, ...}: let
  inputPaths = [
    ["buildInputs"]
    ["nativeBuildInputs"]
    ["propagatedBuildInputs"]
    ["propagatedNativeBuildInputs"]
    ["depsBuildBuild"]
    ["depsBuildTarget"]
    ["depsHostHost"]
    ["depsTargetTarget"]
    ["stdenv" "initialPath"]
    ["stdenv" "defaultBuildInputs"]
    ["stdenv" "defaultNativeBuildInputs"]
    ["initialPath"]
    ["defaultBuildInputs"]
    ["defaultNativeBuildInputs"]
  ];
in
  lib.fix (idr-lib: rec {
    /**
    Information about team.
    */
    team = let
      team_path = "${top.team}/team.toml";
    in
      if builtins.pathExists team_path
      then builtins.fromTOML (builtins.readFile team_path)
      else {};

    /**
    Generate a deterministic IPv6 address using a prefix and some entropy text.

    # Example

    ```nix
    mkIPv6 "fd00:1234" "my-entropy"
    =>
    "fd00:1234:a0b1:861f:8e8f:6344:de5e:631a"
    ```

    # Type

    ```
    mkIPv6 :: String -> String -> String
    ```

    # Arguments

    prefix
    : An IPv6 prefix like "fd00:abcd"

    text
    : Textual entropy used to derive the address
    */
    mkIPv6 = prefix: text: let
      prefix_split = lib.splitString ":" prefix;
      prefix_split_len = builtins.length prefix_split;
      prefix_segments =
        lib.genList
        (i: let
          s = builtins.elemAt prefix_split i;
        in
          if s == "" || i == prefix_split_len - 1
          then s
          else lib.fixedWidthString 4 "0" s)
        prefix_split_len;
      hash = (lib.concatStringsSep "" prefix_segments) + builtins.hashString "sha256" text;
      segments = lib.genList (i: builtins.substring (i * 4) 4 hash) 8;
      normalizeSegment = segment: lib.toLower (lib.toHexString (lib.fromHexString segment));
    in
      lib.concatStringsSep ":" (builtins.map normalizeSegment segments);

    /**
    Like mkIPv6, but returns only specified amount of segments.

    # Example

    ```nix
    mkIPv6Segments "fd00:1234" 5 "my-entropy"
    =>
    "fd00:1234:a0b1:861f:8e8f"
    ```

    # Type

    ```
    mkIPv6Segments :: String -> Int -> String -> String
    ```

    # Arguments

    prefix
    : An IPv6 prefix like "fd00:abcd"

    total_segments
    : Number of segments (max = 8)

    text
    : Textual entropy used to derive the address
    */
    mkIPv6Segments = prefix: total_segments: text: let
      ip = mkIPv6 prefix text;
      segments = lib.take total_segments (lib.splitString ":" ip);
    in
      lib.concatStringsSep ":" segments;

    /**
    # Type


        types.secret :: OptionType


    Used for handling secrets in NixOS configuration.
    */
    types.secret = lib.types.submodule {
      options = {
        path = lib.mkOption {
          description = ''
            Path to the secret file.
          '';
          type = lib.types.path;
        };
        group = lib.mkOption {
          description = ''
            Group which has access to the secret file.
          '';
          type = lib.types.str;
        };
        reloadTarget = lib.mkOption {
          description = ''
            A systemd target, which will be reloaded when secret is changed.
          '';
          type = lib.types.str;
        };
        restartTarget = lib.mkOption {
          description = ''
            A systemd target, which will be restarted when secret is changed.
          '';
          type = lib.types.str;
        };
      };
    };

    /**
    # Type


        types.secretSource :: OptionType


    How a secret is derived, as in `idr.secrets-source.<name>`: a key in a SOPS
    file, or a file generated from other secrets.
    */
    types.secretSource = lib.types.submodule ({name, ...}: {
      options = {
        key = lib.mkOption {
          description = ''
            SOPS secret key.
          '';
          type = lib.types.str;
          defaultText = "<name>";
          default = name;
        };
        sopsFile = lib.mkOption {
          description = ''
            SOPS file to read a secret from.

            If specified, then "exec"/"template"/"secrets" fields will be ignored,
              instead secret will be extracted from sops file using "key" field.
          '';
          type = lib.types.nullOr lib.types.path;
          default = null;
        };
        format = lib.mkOption {
          description = ''
            Format of the SOPS file. When null, use sops-nix's configured format
            (YAML by default); sops-nix does not infer it from the file extension.
          '';
          type = lib.types.nullOr (lib.types.enum ["yaml" "json" "binary" "dotenv" "ini"]);
          default = null;
        };
        path = lib.mkOption {
          description = ''
            Custom runtime path for a SOPS secret. When null, use sops-nix's
            default path. Read the resolved path from config.idr.secrets.<name>.path.
          '';
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        restartUnits = lib.mkOption {
          description = "Additional systemd units for sops-nix to restart when this SOPS secret changes.";
          type = lib.types.listOf lib.types.str;
          default = [];
        };
        reloadUnits = lib.mkOption {
          description = "Additional systemd units for sops-nix to reload when this SOPS secret changes.";
          type = lib.types.listOf lib.types.str;
          default = [];
        };
        recipientMachines = lib.mkOption {
          description = ''
            Machines of other projects that read this SOPS file; they become
            recipients of it. Machines of the same project that use this source
            become recipients without being listed.
          '';
          type = lib.types.listOf lib.types.raw;
          default = [];
          example = lib.literalExpression "[ inputs.etcd.nixosConfigurations.etcd-1 ]";
        };
        exec = lib.mkOption {
          description = ''
            Shell code or an executable derivation to generate the secret. When
            null and no template is set, the secrets become a systemd
            EnvironmentFile.
          '';
          type = lib.types.nullOr (lib.types.coercedTo lib.types.package toString lib.types.str);
          default = null;
        };
        template = lib.mkOption {
          description = ''
            Template with variables, which will be processed via envsubst.

            If specified, takes precedence over exec script.
          '';
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        secrets = lib.mkOption {
          description = ''
            Secrets available to the exec script or the template, as references
            or sources.
          '';
          type = lib.types.attrsOf idr-lib.types.secretOrSource;
          default = {};
          # The documentation would otherwise recurse into nested sources.
          visible = "shallow";
        };
      };
    });

    /**
    # Type


        types.secretOrSource :: OptionType


    A runtime secret reference, such as `config.idr.secrets.<name>`, or a
    secret source (`types.secretSource`), such as
    `{ sopsFile = ./x.enc.json; key = "password"; }`.
    */
    types.secretOrSource = let
      reference = lib.types.addCheck idr-lib.types.secret idr-lib.isSecret;
      source = idr-lib.types.secretSource;
    in
      lib.types.either reference source
      // {
        name = "secretOrSource";
        description = "secret reference or secret source";
        descriptionClass = "noun";
        inherit (source) getSubOptions;
      };

    /**
    Import all `flake-module.nix` files from subdirectories in a given folder.

    # Example

    ```nix
    importFlakeModules ./modules {}
    ```

    # Type

    ```
    importFlakeModules :: Path -> AttrSet -> AttrSet
    ```

    # Arguments

    directory
    : A directory whose subfolders may contain `flake-module.nix`

    args
    : The arguments passed to each module
    */
    importFlakeModules = directory: args: let
      args' = args // {inherit idr-lib;};
    in
      lib.concatMapAttrs (name: _: let
        modulePath = directory + "/${name}/flake-module.nix";
      in
        lib.optionalAttrs (lib.pathIsRegularFile modulePath) {
          "${name}" = lib.modules.importApply modulePath args';
        })
      (builtins.readDir directory);

    /**
    Import `.nix` files directly inside a directory using `importApplyAll`.
    Each file takes the supplied arguments and returns a module.

    # Example

    ```nix
    imports = importModules ./config top;
    ```

    # Type

    ```
    importModules :: Path -> AttrSet -> [Module]
    ```

    # Arguments

    directory
    : A directory containing module files

    args
    : The arguments passed to each module
    */
    importModules = directory: args:
      importApplyAll args (
        lib.mapAttrsToList (name: _: directory + "/${name}") (
          lib.filterAttrs (name: _: lib.hasSuffix ".nix" name && lib.pathIsRegularFile (directory + "/${name}"))
          (builtins.readDir directory)
        )
      );

    /**
    Import a list of module files with the supplied arguments.

    # Example

    ```nix
    importApplyAll {} [./module-a.nix ./module-b.nix]
    ```

    # Type

    ```
    importApplyAll :: AttrSet -> [Path] -> [Module]
    ```

    # Arguments

    args
    : The arguments passed to each module

    modules
    : Module file paths
    */
    importApplyAll = args: modules: builtins.map (module: lib.modules.importApply module args) modules;

    /**
    Collect all non-self recursive flake inputs into a flat list, with one
    entry per source path.

    # Type

    ```
    collectFlakeInputs :: AttrSet -> List AttrSet
    ```

    # Arguments

    inputs
    : The flake inputs
    */
    collectFlakeInputs = inputs: let
      go = result: input: (
        if builtins.elem input result
        then []
        else ([input] ++ lib.concatMap (go (result ++ [input])) (builtins.attrValues (input.inputs or {})))
      );
      # Traverse before deduplicating: the same source can be instantiated with
      # different input overrides, whose dependencies must all remain available.
      allInputs = lib.concatMap (go []) (lib.attrValues (builtins.removeAttrs inputs ["self"]));
      collected =
        lib.foldl' (acc: input: let
          # Hash lazy-tree paths before using them as attribute keys.
          key = builtins.unsafeDiscardStringContext (builtins.hashString "sha256" (toString input));
        in
          if acc.seen ? ${key}
          then acc
          else {
            seen = acc.seen // {${key} = true;};
            result = acc.result ++ [input];
          }) {
          seen = {};
          result = [];
        }
        allInputs;
    in
      collected.result;

    /**
    Generate a deterministic local IPv6 address using a preset prefix.
    Can be used in conjuction with idr.preset.loopback.addresses for internal communication.
    For example, application will listen on local IPv6 address, and traefik will communicate with application using that address.

    # Type

    ```
    mkLocalIPv6 :: String -> String
    ```

    # Arguments

    text
    : Entropy text used to derive the IPv6 address
    */
    mkLocalIPv6 = mkIPv6 "fdcd:2227:0b15";

    /**
    Check whether a string is an IPv6 address without a prefix length.

    # Type

    ```
    isIPv6 :: String -> Bool
    ```

    # Arguments

    ip
    : A string potentially representing an IPv6 address
    */
    isIPv6 = ip: let
      octet = "(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])";
      ipv4Tail = builtins.match "(.*:)${octet}\\.${octet}\\.${octet}\\.${octet}" ip;
      # A dotted IPv4 tail occupies two hextets; only its width matters here.
      address =
        if ipv4Tail == null
        then ip
        else "${builtins.head ipv4Tail}0:0";
    in
      !(lib.hasInfix "/" ip)
      && lib.all (part: builtins.stringLength part <= 4) (lib.splitString ":" address)
      && (builtins.tryEval (lib.network.ipv6.fromString address).address).success;

    /**
    Like mkLocalIPv6, but uses podman's default network as prefix.

    # Type

    ```
    mkContainerIPv6 :: String -> String
    ```

    # Arguments

    text
    : Entropy text used to derive the IPv6 address
    */
    mkContainerIPv6 = mkIPv6 "fda8:35f4:8bb1";

    /**
    Extract all unique derivation inputs from a set of derivations.
    Useful to add all dependencies to dev shell.

    # Type

    ```
    inputsFrom :: [Derivation] -> [Derivation]
    ```

    # Arguments

    inputsFrom
    : List of derivations from which to collect inputs
    */
    inputsFrom = packages: let
      getInputs = pkg:
        lib.concatMap (path: lib.attrByPath path [] pkg) inputPaths;
    in
      lib.unique (
        builtins.filter lib.isDerivation (
          lib.concatMap getInputs packages
        )
      );

    transitiveInputsFrom = seed: let
      go = current: let
        currentSet = builtins.listToAttrs (
          map (x: {
            name = builtins.unsafeDiscardStringContext x.outPath;
            value = true;
          })
          current
        );
        new = builtins.filter (x: !(currentSet ? ${builtins.unsafeDiscardStringContext x.outPath})) (inputsFrom current);
      in
        if new == []
        then current
        else go (current ++ new);
    in
      go seed;

    /**
    Format an host for URL usage, wrapping IPv6 addresses in square brackets.

    This is useful when constructing URLs with literal IPs, as IPv6 must be enclosed
    in brackets (e.g., `[::1]:8080`) to be valid in URI form. IPv4 addresses and domains are returned unchanged.

    # Example

        normalizeHost "192.168.1.1"
        => "192.168.1.1"

        normalizeHost "fd00::1"
        => "[fd00::1]"

    # Type

        normalizeHost :: String -> String

    # Arguments

    ip
    : A string representing an IPv4 or IPv6 address
    */
    normalizeHost = host:
      if lib.hasInfix ":" host && !(lib.hasPrefix "[" host)
      then "[${host}]"
      else host;

    /**
    Check whether a value has exactly the fields used by `types.secret`.

    # Type

        isSecret :: Any -> Bool

    # Arguments

    value
    : The value to check
    */
    isSecret = value:
      builtins.isAttrs value
      && builtins.attrNames value == ["group" "path" "reloadTarget" "restartTarget"];

    /**
    Generate a sha512 hash & returns first n letters.

    # Type

    ```
    shortHash :: Int -> String -> String
    ```

    # Arguments

    size
    : Number of characters.

    text
    : Input text
    */
    shortHash = size: text: builtins.substring 0 size (builtins.hashString "sha512" text);

    /**
    Read the domains of a certificate issued by `idr-update-certs` from its JSON
    SOPS file, where they are saved unencrypted.

    # Type

        certificateDomains :: String -> Path -> [String]

    # Arguments

    name
    : The certificate's name, as in `idr.certs`

    sopsFile
    : The JSON SOPS file holding the certificate
    */
    certificateDomains = name: sopsFile: let
      key = "${name}_domains_unencrypted";
    in
      # Nix reads JSON, but not YAML.
      if lib.hasSuffix ".json" (toString sopsFile)
      then (lib.importJSON sopsFile).${key} or (throw "Certificate ${name}: ${toString sopsFile} has no ${key}; run idr-update-certs.")
      else throw "Certificate ${name}: domains can only be read from a JSON file, not ${toString sopsFile}.";

    /**
    # Type


        types.sopsSource :: OptionType


    A key in a SOPS file. Unlike a runtime secret reference, another machine can
    read it too when it is a recipient of the file.
    */
    types.sopsSource = lib.types.submodule {
      options = {
        sopsFile = lib.mkOption {
          description = "SOPS file containing the secret.";
          type = lib.types.path;
        };
        key = lib.mkOption {
          description = "Key of the secret in the file.";
          type = lib.types.str;
        };
        format = lib.mkOption {
          description = "Format of the SOPS file.";
          type = lib.types.enum ["yaml" "json" "binary" "dotenv" "ini"];
          default = "json";
        };
      };
    };

    /**
    Derive etcd users and roles for the mesh agents of some machines in one of
    their `idr.mesh.etcd` clusters, for `idr.etcd.clusters.<name>.rbac`. Each
    machine with the mesh enabled and that cluster gets its own user and role
    named after the cluster's `username`: read and write on the services it
    declares in the cluster, and read on their peers. The user's password is
    the cluster's `password` when that is a secret source:
    RBAC machines of the same project become recipients of its SOPS file, and
    those of other projects must be listed in its `recipientMachines`. When it
    is a secret reference, set the user's `password` on the RBAC machine
    yourself.

    # Example

    ```nix
    idr.etcd.clusters.main.rbac = lib.mkMerge [
      { ... }
      (idr-lib.meshRbac "main" self.nixosConfigurations)
    ];
    ```

    # Type

    ```
    meshRbac :: String -> AttrSet -> { roles :: AttrSet, users :: AttrSet }
    ```

    # Arguments

    cluster
    : The name of the cluster in `idr.mesh.etcd`

    nixosConfigurations
    : The machines that may use the cluster
    */
    meshRbac = import ../mesh/rbac.nix {inherit lib;};
  })

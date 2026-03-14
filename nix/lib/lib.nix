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
    Collect all non-self recursive flake inputs into a flat list.

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
    in
      lib.concatMap
      (go [])
      (lib.attrValues (lib.filterAttrs (n: v: n != "self") inputs));

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
  })

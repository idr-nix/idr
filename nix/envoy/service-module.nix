top: {
  config,
  lib,
  systemdPackage,
  ...
}: let
  inherit (lib) mkOption types;
  inherit (top.idr-lib) isSecret;
  cfg = config.idr.envoy;
  # Service modules receive no pkgs; the service manager's package tells the
  # machine's system.
  inherit (systemdPackage.stdenv.hostPlatform) system;
  pkgs = top.inputs.nixpkgs.legacyPackages.${system};

  json =
    types.nullOr (types.oneOf [
      types.bool
      types.int
      types.float
      types.str
      types.path
      (types.attrsOf json)
      jsonList
    ])
    // {description = "JSON value";};

  # Fields holding lists of header, query parameter, cookie or key-value
  # matchers, or of JWT headers, in Envoy 1.40's API. Their elements' names are
  # the data to match, and several elements may share one.
  unnamedLists = [
    "headers"
    "retriable_headers"
    "retriable_request_headers"
    "allow_failed_matcher"
    "deny_redirect_matcher"
    "pass_through_matcher"
    "query_parameters"
    "query_parameters_excluded"
    "query_parameters_included"
    "cookies"
    "properties"
    "from_headers"
  ];

  # When every element of a list, across all definitions, is an object with a
  # name, the elements with the same name merge, in the order in which names
  # first appear. Other lists, and those in unnamedLists, concatenate, keeping
  # one of equal elements. Modules can so add filter chains to a listener, or
  # virtual hosts to a route table, and share elements.
  # Elements may be wrapped in mkIf, mkMerge or a priority, as definitions.
  jsonList = types.mkOptionType {
    name = "jsonList";
    description = "list of JSON values, merged by name when all are named objects";
    descriptionClass = "noun";
    check = lib.isList;
    merge = loc: defs: let
      # The elements behind mkMerge and true mkIf, as definitions would be.
      discharge = value:
        if value._type or null == "merge"
        then lib.concatMap discharge value.contents
        else if value._type or null == "if"
        then lib.optionals value.condition (discharge value.content)
        else [value];
      entries = lib.concatMap (def:
        lib.concatMap (element:
          map (value: {
            inherit (def) file;
            inherit value;
          }) (discharge element))
        def.value)
      defs;
      nameOf = entry: let
        value =
          if entry.value._type or null == "override"
          then entry.value.content
          else entry.value;
      in
        if lib.isAttrs value
        then value.name or null
        else null;
      named = !lib.elem (lib.last loc) unnamedLists && lib.all (entry: lib.isString (nameOf entry)) entries;
      names = lib.unique (map nameOf entries);
    in
      if named
      then
        map (name:
          json.merge (loc ++ [name])
          (lib.modules.filterOverrides (lib.filter (entry: nameOf entry == name) entries)))
        names
      else lib.unique ((types.listOf json).merge loc defs);
  };

  # Fields that refer to a secret by name, in Envoy 1.40's API.
  secretFields = [
    "tls_certificate_sds_secret_configs"
    "validation_context_sds_secret_config"
    "session_ticket_keys_sds_secret_config"
    "token_secret"
    "hmac_secret"
    "encryption_parameters"
    "credential"
    "client_secret"
  ];

  bootstrap = builtins.removeAttrs cfg ["package" "args" "resources"];
  inherit (cfg) resources;
  routes = lib.listToAttrs (map (route: lib.nameValuePair route.name route) resources.routes);
  secrets = map (secret: secret.name) resources.secrets;

  # Domains that a listener's server name matcher sends to several filter
  # chains, which Envoy refuses, each with those chains.
  repeatedDomains = lib.concatMap (listener: let
    matchers = listener.filter_chain_matcher.matcher_tree.custom_match.typed_config.domain_matchers or [];
    claims = lib.concatMap (matcher:
      map (domain: {
        inherit domain;
        chain = matcher.on_match.action.name or "?";
      }) (matcher.domains or []))
    matchers;
  in
    lib.mapAttrsToList (domain: claimed: "${domain} in listener ${listener.name or "?"}: ${lib.concatMapStringsSep ", " (claim: claim.chain) claimed}")
    (lib.filterAttrs (_: claimed: lib.length claimed > 1) (lib.groupBy (claim: claim.domain) claims)))
  resources.listeners;

  collect = value:
    if isSecret value
    then [value]
    else if lib.isAttrs value
    then lib.concatMap collect (lib.attrValues value)
    else if lib.isList value
    then lib.concatMap collect value
    else [];
  # Secrets that only a new Envoy process reads again. Envoy 1.40 watches the
  # files of certificates, keys, CAs, CRLs and generic secrets in
  # resources.secrets; it reads other fields there, such as session ticket keys
  # or an OCSP staple, and secrets elsewhere, such as in a listener, once.
  unwatched = secret:
    secret
    // lib.optionalAttrs (secret ? tls_certificate) {
      tls_certificate = builtins.removeAttrs secret.tls_certificate ["certificate_chain" "private_key"];
    }
    // lib.optionalAttrs (secret ? validation_context) {
      validation_context = builtins.removeAttrs secret.validation_context ["trusted_ca" "crl"];
    }
    // lib.optionalAttrs (secret ? generic_secret) {
      generic_secret = builtins.removeAttrs secret.generic_secret ["secret" "secrets"];
    };
  staticReferences = lib.unique (collect bootstrap
    ++ lib.concatMap collect (resources.listeners ++ resources.clusters ++ resources.routes)
    ++ lib.concatMap (secret: collect (unwatched secret)) resources.secrets);
  references = lib.unique (staticReferences ++ collect resources);
  hashed = text: builtins.substring 0 16 (builtins.hashString "sha256" text);
  credential = secret: "secret-${hashed secret.path}";

  # The service manager names the unit after the service's full name, as it
  # names the directory of the service's configuration data.
  directory = dirOf config.configData."envoy.json".path;
  unit = baseNameOf directory;
  runtimeDirectory = "idr-envoy-${unit}";
  runtime = "/run/${runtimeDirectory}";
  routeFile = name: "xds/routes/${hashed name}.json";
  secretFile = name: "xds/secrets/${hashed name}.json";
  source = file: {
    path_config_source = {
      path = "${runtime}/${file}";
      watched_directory.path = dirOf "${runtime}/${file}";
    };
    resource_api_version = "V3";
  };

  # Secret references become files; validation reads the staged ones, which
  # are only installed once valid. Route tables and secrets of resources,
  # referred to by name, are loaded from their files when dynamic, and are
  # inlined otherwise, for validation.
  prepare = dynamic: let
    secretReference = reference:
      if lib.isAttrs reference && lib.elem (reference.name or null) secrets && !(reference ? sds_config) && dynamic
      then reference // {sds_config = source (secretFile reference.name);}
      else reference;
    routeTable = value: let
      name = value.rds.route_config_name or null;
    in
      if lib.isString name && routes ? ${name} && !(value.rds ? config_source)
      then
        if dynamic
        then value // {rds = value.rds // {config_source = source (routeFile name);};}
        else builtins.removeAttrs value ["rds"] // {route_config = routes.${name};}
      else value;
    walk = value:
      if isSecret value
      then {
        filename = "${runtime}/${
          if dynamic
          then "secrets"
          else "staged"
        }/${credential value}";
      }
      else if lib.isAttrs value
      then
        lib.mapAttrs (field: inner:
          if lib.elem field secretFields
          then
            if lib.isList inner
            then map secretReference (walk inner)
            else secretReference (walk inner)
          else walk inner) (routeTable value)
      else if lib.isList value
      then map walk value
      else value;
  in
    walk;

  # A discovery response, as Envoy reads it from a file.
  response = type: items:
    builtins.toJSON {
      version_info = hashed (builtins.toJSON items);
      resources = map (item: {"@type" = "type.googleapis.com/${type}";} // prepare true item) items;
    };

  supervisor = lib.getExe (pkgs.writers.writeNuBin "idr-envoy-supervisor" {
    makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.coreutils pkgs.util-linux systemdPackage])];
  } (builtins.readFile ./supervisor.nu));
  files =
    {
      "envoy.json" = let
        prepared = prepare true bootstrap;
      in
        builtins.toJSON (prepared
          // {
            dynamic_resources =
              (prepared.dynamic_resources or {})
              // {
                lds_config = source "xds/lds.json";
                cds_config = source "xds/cds.json";
              };
          });
      "validate.json" = let
        prepared = prepare false bootstrap;
        static = prepared.static_resources or {};
      in
        builtins.toJSON (prepared
          // {
            static_resources =
              static
              // lib.genAttrs ["listeners" "clusters" "secrets"] (kind:
                (static.${kind} or []) ++ map (prepare false) resources.${kind});
          });
      command = lib.concatLines ([(lib.getExe cfg.package)] ++ cfg.args);
      secrets =
        lib.concatMapStrings (secret: "${secret.path} ${credential secret} ${
          if lib.elem secret staticReferences
          then "static"
          else "dynamic"
        }\n")
        references;
      "xds/lds.json" = response "envoy.config.listener.v3.Listener" resources.listeners;
      "xds/cds.json" = response "envoy.config.cluster.v3.Cluster" resources.clusters;
    }
    // lib.mapAttrs' (name: route:
      lib.nameValuePair (routeFile name) (response "envoy.config.route.v3.RouteConfiguration" [route]))
    routes
    // lib.listToAttrs (map (secret:
      lib.nameValuePair (secretFile secret.name) (response "envoy.extensions.transport_sockets.tls.v3.Secret" [secret]))
    resources.secrets);
in {
  _class = "service";
  key = toString ./service-module.nix;
  imports = [top.self.modules.service.mesh];

  options.idr.envoy = mkOption {
    description = ''
      Envoy's bootstrap configuration, in Envoy's own format. A change starts a
      new Envoy process that takes over the listeners. In lists whose elements
      all have a `name`, elements with the same name merge, except in lists of
      matchers; other lists concatenate. A secret reference in place of a data
      source becomes a file that Envoy reads.
    '';
    default = {};
    type = types.submodule {
      freeformType = types.attrsOf json;
      options = {
        package = mkOption {
          type = types.package;
          default = top.self.packages.${system}.envoy;
          defaultText = "idr's Envoy package";
          description = "Envoy package to run. It is not part of the configuration.";
        };
        args = mkOption {
          type = types.listOf types.str;
          default = [];
          example = ["--drain-time-s" "60" "--parent-shutdown-time-s" "90"];
          description = "Additional Envoy command line arguments. They are not part of the configuration.";
        };
        resources = mkOption {
          default = {};
          description = ''
            Resources that Envoy loads from files and updates without a new
            process, in Envoy's formats for listeners, clusters, route tables
            and secrets. They are not part of the bootstrap. A connection
            manager's `rds.route_config_name` and a TLS context's secret names
            refer to them.
          '';
          type = types.submodule {
            options = lib.genAttrs ["listeners" "clusters" "routes" "secrets"] (kind:
              mkOption {
                type = jsonList;
                default = [];
                description = "Envoy ${kind}, merged by name.";
              });
          };
        };
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.all (argument: !lib.hasInfix "\n" argument) cfg.args;
        message = "idr.envoy.args must not contain newlines.";
      }
      {
        assertion = !(bootstrap ? dynamic_resources.lds_config || bootstrap ? dynamic_resources.cds_config);
        message = "idr.envoy loads listeners and clusters from idr.envoy.resources; do not set dynamic_resources.lds_config or cds_config.";
      }
      {
        assertion = repeatedDomains == [];
        message = "idr.envoy: each domain must lead to one filter chain, but these lead to several:\n${lib.concatStringsSep "\n" repeatedDomains}";
      }
    ];

    # Envoy needs a node identity to load dynamic resources.
    idr.envoy.node = {
      id = lib.mkDefault unit;
      cluster = lib.mkDefault unit;
    };

    configData = lib.mapAttrs (_: text: {inherit text;}) files;

    # Each Envoy on a machine needs its own base ID for hot restarts.
    process.argv = [
      supervisor
      "run"
      directory
      (toString (lib.fromHexString (builtins.substring 0 6 (builtins.hashString "sha256" unit))))
    ];

    # Every change is applied by a reload, so that deployments never stop
    # Envoy: the configuration, the package and the secrets are read from
    # files. Changed resources update the running Envoy; other changes start a
    # new Envoy that takes over the listeners. Changes of this unit's own
    # settings take effect when the service next restarts.
    systemd.service = let
      targets = map (secret: secret.reloadTarget) references;
      copySecrets = "+${supervisor} secrets ${directory}";
    in {
      reloadIfChanged = true;
      restartTriggers = lib.attrValues files;
      # Not partOf the targets: removing a secret stops its target, which
      # must not stop Envoy.
      wants = targets;
      after = targets;
      unitConfig.ReloadPropagatedFrom = targets;
      serviceConfig = {
        DynamicUser = true;
        RuntimeDirectory = runtimeDirectory;
        RuntimeDirectoryMode = "0700";
        ExecStartPre = [copySecrets "${supervisor} install ${directory}"];
        ExecReload = [copySecrets "${supervisor} reload ${directory}"];
        AmbientCapabilities = ["CAP_NET_BIND_SERVICE"];
        CapabilityBoundingSet = ["CAP_NET_BIND_SERVICE"];
      };
    };
  };
}

top: moduleArgs @ {
  inputs,
  config,
  pkgs,
  lib,
  options,
  ...
}: let
  inherit (top.idr-lib) isSecret;
  secrets-source = config.idr.secrets-source;
  isSopsSecret = source: source.sopsFile != null;
  # A source's reference follows from its name alone.
  reference = name: source: {
    path =
      if isSopsSecret source
      then config.sops.secrets.${name}.path
      else "/run/idr-secrets/${name}";
    group = "keys_${name}";
    reloadTarget = "op-key-${name}-reload.target";
    restartTarget = "op-key-${name}-restart.target";
  };
  resolve = name: value:
    if isSecret value
    then value
    else reference name value;
  # The sources to provide, including those nested in a generated secret's
  # inputs, which are named after their parent and variable. A reference is an
  # alias and provides nothing. A reference may itself be read from
  # idr.secrets, so the keys of idr.secrets-source and idr.secrets must not
  # depend on telling references from sources: both are lazy attribute sets,
  # and idr.secrets lists only the top-level names.
  flatten = prefix: values:
    lib.concatLists (lib.mapAttrsToList (name: value: let
      full = prefix + name;
    in
      lib.optionals (!isSecret value) (
        [(lib.nameValuePair full (value // {secrets = lib.mapAttrs (variable: resolve "${full}-${variable}") value.secrets;}))]
        ++ flatten "${full}-" value.secrets
      ))
    values);
  flattened = flatten "" secrets-source;
  sources = lib.listToAttrs flattened;
  sopsSources = lib.filterAttrs (_: isSopsSecret) sources;
  # Without exec or template, the inputs become a systemd EnvironmentFile.
  environmentFile = names: ''
    ${pkgs.jq}/bin/jq -rn \
      '$ARGS.positional[] as $name
        | $name + "=\"" + (
            $ENV[$name]
            | split("\\") | join("\\\\")
            | split("\"") | join("\\\"")
          ) + "\""' \
      --args ${lib.escapeShellArgs names}
  '';
in {
  key = toString ./nixos-module.nix;

  imports = [(lib.modules.importApply ./services.nix top)];

  options.idr = {
    secrets-source = lib.mkOption {
      description = ''
        Declarative secret sources specifying how each secret is derived from SOPS or exec scripts.
        A secret reference makes the name an alias of that secret.
      '';
      type = lib.types.lazyAttrsOf top.idr-lib.types.secretOrSource;
      default = {};
      example = lib.literalExpression ''
        {
          foo1 = {
            key = "foo";
            sopsFile = ./secrets.enc.yaml;
          };
          foo2 = {
            secrets.foo1 = config.idr.secrets.foo1;
          };
          foo3 = {
            exec = "printf '%s' \"$foo2\"";
            secrets.foo2 = config.idr.secrets.foo2;
          };
          foo4 = {
            template = "Substitute variables $FOO1 and $FOO2 via envsubst";
            secrets.FOO1 = config.idr.secrets.foo1;
            secrets.FOO2 = config.idr.secrets.foo2;
          };
        }
      '';
    };
    secrets = lib.mkOption {
      description = ''
        Resolved secrets generated from idr.secrets-source, providing paths and access control metadata.
      '';
      type = lib.types.lazyAttrsOf top.idr-lib.types.secret;
      default = {};
    };
    secrets-sops-files = lib.mkOption {
      description = "SOPS files this machine reads secrets from, each with the machines of other projects its source names as recipients.";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      # Not deduplicated: comparing machine configurations would evaluate them.
      default =
        lib.mapAttrsToList (_: source: {
          file = source.sopsFile;
          inherit (source) recipientMachines;
        })
        sopsSources;
      defaultText = "The SOPS files of idr.secrets-source, including nested sources.";
    };
  };
  config = lib.mkMerge [
    {
      idr.secrets = lib.mapAttrs resolve secrets-source;

      systemd.tmpfiles.rules = lib.optional (sources == {}) "R /run/idr-secrets - - - -";

      assertions = lib.optionals (sources != {}) [
        {
          assertion = options ? sops;
          message = "sops module must be imported.";
        }
        {
          assertion =
            lib.all
            (name: isSopsSecret sources.${name} || !(builtins.elem name [".out" ".secret" ".ignore" ".input-hashes"]))
            (builtins.attrNames sources);
          message = "Generated idr.secrets-source names must not be .out, .secret, .ignore, or .input-hashes.";
        }
        {
          assertion = lib.allUnique (map (entry: entry.name) flattened);
          message = "idr.secrets-source: a nested source is named <parent>-<variable>, which must not be the name of another source.";
        }
      ];
    }

    (lib.mkIf (sources != {}) (lib.optionalAttrs (options ? sops) {
      users.groups =
        (lib.concatMapAttrs
          (name: secret: {
            "keys_${name}" = {};
          })
          sources)
        // {
          keys = {};
        };

      systemd.targets =
        lib.concatMapAttrs
        (name: secret: {
          "op-key-${name}-reload" = rec {
            wantedBy = lib.optional (isSopsSecret secret) "multi-user.target" ++ after;
            after = lib.optionals (!isSopsSecret secret) (lib.mapAttrsToList (name: s: s.reloadTarget) secret.secrets);
            partOf = after;
            unitConfig.ReloadPropagatedFrom = after;
          };
          "op-key-${name}-restart" = rec {
            wantedBy = lib.optional (isSopsSecret secret) "multi-user.target" ++ after;
            after = lib.optionals (!isSopsSecret secret) (lib.mapAttrsToList (name: s: s.restartTarget) secret.secrets);
            partOf = after;
          };
        })
        sources;

      systemd.services.idr-secrets = let
        templateSecrets = lib.filterAttrs (name: secret: !(isSopsSecret secret)) sources;
        templateNames = builtins.attrNames templateSecrets;
        isDependency = producer: consumer:
          lib.any
          (secret: toString secret.path == toString (reference producer templateSecrets.${producer}).path)
          (builtins.attrValues templateSecrets.${consumer}.secrets);
        templateOrder = lib.toposort isDependency templateNames;
        orderedTemplateNames =
          if lib.any (name: isDependency name name) templateNames || templateOrder ? cycle
          then throw "idr.secrets-source contains a dependency cycle"
          else templateOrder.result;
      in rec {
        wantedBy =
          ["sysinit.target" "sysinit-reactivation.target"]
          ++ (lib.flatten
            (lib.mapAttrsToList
              (name: template: ["op-key-${name}-reload.target" "op-key-${name}-restart.target"])
              templateSecrets));
        before = wantedBy;
        partOf = wantedBy;
        after = lib.optional (config.systemd.services ? sops-install-secrets) "sops-install-secrets.service";
        requires = after;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          RuntimeDirectory = "idr-secrets";
          RuntimeDirectoryMode = "0751";
          RuntimeDirectoryPreserve = true;
          UMask = "0077";
          Group = config.users.groups.keys.name;
        };
        unitConfig = {
          DefaultDependencies = "no";
          ReloadPropagatedFrom = lib.mapAttrsToList (name: _: "op-key-${name}-reload.target") sources;
        };
        path = with pkgs; [gettext bash ripgrep findutils diffutils coreutils];
        restartIfChanged = true;
        script = ''
          set -euo pipefail
          trap 'rm -f "$RUNTIME_DIRECTORY/.out" "$RUNTIME_DIRECTORY/.secret"' EXIT
          rm -f "$RUNTIME_DIRECTORY/.out" "$RUNTIME_DIRECTORY/.secret"
          mkdir -p "$RUNTIME_DIRECTORY/.input-hashes"
          rm -f "$RUNTIME_DIRECTORY/.ignore" "$RUNTIME_DIRECTORY/.input-hashes/.ignore"
          touch "$RUNTIME_DIRECTORY/.ignore" "$RUNTIME_DIRECTORY/.input-hashes/.ignore"

          ${lib.concatStringsSep "\n" (map (templateName: let
              template = templateSecrets.${templateName};
              group = config.users.groups."keys_${templateName}".name;
              vars = lib.mapAttrsToList (name: secret: "\$${name}") template.secrets;
              mkSecret = pkgs.writeScript "mk-secret.sh" (
                if template.template != null
                then ''
                  printf '%s' ${lib.escapeShellArg template.template} \
                    | ${pkgs.gettext}/bin/envsubst ${lib.escapeShellArg (lib.concatStringsSep " " vars)}
                ''
                else if template.exec != null
                then template.exec
                else environmentFile (builtins.attrNames template.secrets)
              );
            in ''
              echo "/${templateName}" >> "$RUNTIME_DIRECTORY/.ignore"
              echo "/${templateName}" >> "$RUNTIME_DIRECTORY/.input-hashes/.ignore"

              idr_secret_bindings=()
              ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: secret: ''
                  idr_secret_value="$(cat ${lib.escapeShellArg "${secret.path}"} && printf '.')"
                  idr_secret_value="''${idr_secret_value%.}"
                  idr_secret_bindings+=(${lib.escapeShellArg "${name}="}"$idr_secret_value")
                '')
                template.secrets)}

              if ! [[ -f "$RUNTIME_DIRECTORY/.input-hashes/${templateName}" ]]; then
                touch "$RUNTIME_DIRECTORY/.input-hashes/${templateName}"
              fi

              inputs_hash="$(printf '%s\0' "''${idr_secret_bindings[@]}" ${lib.escapeShellArg mkSecret} | sha256sum)"
              previous_inputs_hash="$(cat "$RUNTIME_DIRECTORY/.input-hashes/${templateName}")"
              if [[ "$inputs_hash" != "$previous_inputs_hash" || ! -f "$RUNTIME_DIRECTORY/${templateName}" ]]; then
                out="$RUNTIME_DIRECTORY/.out"
                (
                  set -- "''${idr_secret_bindings[@]}"
                  unset idr_secret_bindings
                  export out "$@"
                  exec ${pkgs.bash}/bin/bash -euo pipefail ${mkSecret}
                ) > "$RUNTIME_DIRECTORY/.secret"
                if [[ -f "$out" ]]; then
                  mv "$out" "$RUNTIME_DIRECTORY/.secret"
                fi
                chown ${lib.escapeShellArg "root:${group}"} "$RUNTIME_DIRECTORY/.secret"
                chmod 0600 "$RUNTIME_DIRECTORY/.secret"

                if ! cmp -s "$RUNTIME_DIRECTORY/.secret" "$RUNTIME_DIRECTORY/${templateName}"; then
                  chmod 0440 "$RUNTIME_DIRECTORY/.secret"
                  mv -Tf "$RUNTIME_DIRECTORY/.secret" "$RUNTIME_DIRECTORY/${templateName}"
                fi

                echo -n "$inputs_hash" > "$RUNTIME_DIRECTORY/.input-hashes/${templateName}"
              fi

              chown ${lib.escapeShellArg "root:${group}"} "$RUNTIME_DIRECTORY/${templateName}"
              chmod 0440 "$RUNTIME_DIRECTORY/${templateName}"
            '')
            orderedTemplateNames)}

           if rg --hidden --glob '!.ignore' "$RUNTIME_DIRECTORY" --files; then
             rg --hidden --glob '!.ignore' "$RUNTIME_DIRECTORY" --files | xargs --no-run-if-empty rm
           fi

          ${lib.optionalString (sopsSources != {}) ''
            ${config.systemd.package}/bin/systemctl --no-block start idr-sops-notify.service
          ''}
        '';
        reload = script;
      };

      # SOPS's systemd unit runs after NixOS reads activation restart lists.
      # Notify after generation finishes: notifications can restart the generator.
      systemd.services.idr-sops-notify = lib.mkIf (sopsSources != {}) {
        after = ["idr-secrets.service"];
        path = [pkgs.coreutils];
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "idr-sops-notify";
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = true;
          UMask = "0077";
        };
        script = ''
          restart_targets=()
          reload_targets=()
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
              inputs_hash=$(sha256sum < ${lib.escapeShellArg config.sops.secrets.${name}.path})
              previous_inputs_hash=""
              hash_file="$RUNTIME_DIRECTORY/"${lib.escapeShellArg name}
              if [[ -f "$hash_file" ]]; then
                previous_inputs_hash=$(< "$hash_file")
              fi
              printf '%s' "$inputs_hash" > "$hash_file"
              if [[ -n "$previous_inputs_hash" && "$previous_inputs_hash" != "$inputs_hash" ]]; then
                restart_targets+=(${lib.escapeShellArg "op-key-${name}-restart.target"})
                reload_targets+=(${lib.escapeShellArg "op-key-${name}-reload.target"})
              fi
            '')
            sopsSources)}

          ${lib.optionalString config.sops.useSystemdActivation ''
            if [[ ''${#restart_targets[@]} -gt 0 ]]; then
              ${config.systemd.package}/bin/systemctl --no-block try-restart "''${restart_targets[@]}"
              ${config.systemd.package}/bin/systemctl --no-block try-reload-or-restart "''${reload_targets[@]}"
            fi
          ''}
        '';
      };

      sops.secrets =
        lib.mapAttrs
        (name: secret:
          {
            inherit (secret) sopsFile key;
            group = config.users.groups."keys_${name}".name;
            mode = "0440";
            reloadUnits = secret.reloadUnits ++ lib.optional (!config.sops.useSystemdActivation) "op-key-${name}-reload.target";
            restartUnits = secret.restartUnits ++ lib.optional (!config.sops.useSystemdActivation) "op-key-${name}-restart.target";
          }
          // lib.optionalAttrs (secret.format != null) {inherit (secret) format;}
          // lib.optionalAttrs (secret.path != null) {inherit (secret) path;})
        sopsSources;
    }))
  ];
}

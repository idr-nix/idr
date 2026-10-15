top: args @ {
  lib,
  config,
  self,
  inputs,
  flake-parts-lib,
  ...
}: let
  inherit (lib) mkOption types;
in {
  imports = [
    top.inputs.git-hooks-nix.flakeModule
  ];

  perSystem = {
    config,
    system,
    pkgs,
    ...
  }: let
    settings = config.pre-commit.settings;
    install = pkgs.writeShellScript "idr-install-git-hooks" ''
      set -euo pipefail
      hooks="$(${lib.getExe settings.gitPackage} rev-parse --path-format=absolute --git-common-dir)/hooks"
      configured="$(${lib.getExe settings.gitPackage} config --get core.hooksPath || true)"
      if [[ -n $configured && $configured != .git/hooks && $configured != "$hooks" ]]; then
        exit 0
      fi
      # A linked worktree inherits the main checkout's relative hook path.
      if [[ $configured == .git/hooks ]]; then
        ${lib.getExe settings.gitPackage} config --local core.hooksPath "$hooks"
      fi

      # Restore native hooks before upstream can preserve an IDR launcher as
      # .legacy. This also preserves hooks using a user-owned configuration.
      reinstall=false
      for hook in "$hooks"/*; do
        [[ -f $hook && ! -L $hook && ''${hook##*/} != *.* ]] || continue
        if ${lib.getExe pkgs.gnugrep} -qxF '# idr-git-hook-launcher-v1' "$hook"; then
          payload="$(${pkgs.gnused}/bin/sed -n 's/^# idr-git-hook-payload: //p' "$hook")"
          if [[ $payload != "''${hook##*/}.idr-"* || $payload == */* || ! -f $hooks/$payload || -L $hooks/$payload ]]; then
            echo "idr: cannot restore the saved native Git hook for $hook" >&2
            exit 1
          fi
          mv -f -- "$hooks/$payload" "$hook"
          rm -f -- "$hook".idr-*
          reinstall=true
        fi
      done
      if $reinstall && [[ -L ${lib.escapeShellArg settings.configPath} ]]; then
        rm -- ${lib.escapeShellArg settings.configPath}
      fi
      (
        ${config.pre-commit.shellHook}
      )
      # Upstream writes a relative path when installing from the main checkout.
      if [[ $(${lib.getExe settings.gitPackage} config --get core.hooksPath) == .git/hooks ]]; then
        ${lib.getExe settings.gitPackage} config --local core.hooksPath "$hooks"
      fi
    '';
  in {
    pre-commit = {
      check.enable = lib.mkDefault false;
    };

    devshells.default = {
      env = [
        {
          name = "PRE_COMMIT_HOME";
          eval = "$(${pkgs.nushell}/bin/nu -n --no-std-lib --no-history -c ${lib.escapeShellArg ''
            use ${../../scripts}/idr-common.nu [host-data-dir]
            host-data-dir | path join "pre-commit"
          ''})";
        }
      ];
      devshell.startup.idr-git-hooks.text = lib.optionalString settings.install.enable ''
        if [[ -e "$PRJ_ROOT/.git" ]]; then
          (cd "$PRJ_ROOT" && idr-with-project-lock ${install})
        fi
      '';
      packages = config.pre-commit.settings.enabledPackages;
    };
  };
}

_: {
  config,
  lib,
  ...
}: let
  cfg = config.idr.test.direnv;
in {
  options.idr.test.direnv = {
    offline = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Apply Nix's offline settings while loading the direnv environment.";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional use_flake arguments passed to nix print-dev-env.";
    };
  };

  config.defaults = {
    # The container test driver sources /etc/profile with an empty environment.
    environment.shellInit = ''
      if [ -z "''${HOME:-}" ]; then
        unset HOME
        export HOME=~
      fi
    '';

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
      direnvrcExtra = ''
        nix_direnv_disallow_fallback

        # Preserve nix-direnv's cache and watches, but stop loading on failure.
        eval "_idr_test_$(declare -f use_flake)"
        use_flake() {
          ${lib.optionalString cfg.offline ''
          # Cover cache creation and flake archive without changing the command's environment.
          local -x NIX_CONFIG="''${NIX_CONFIG-}
          substitute = false
          tarball-ttl = 4294967295
          narinfo-cache-meta-ttl = 4294967295
          filetransfer-retry-attempts = 0
          connect-timeout = 1
          "
        ''}
          # Later .envrc commands must not hide a failed environment load.
          _idr_test_use_flake "$@" ${lib.escapeShellArgs cfg.extraArgs} || exit $?
        }
      '';
    };
  };
}

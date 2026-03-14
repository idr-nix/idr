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
  }: {
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
      devshell.startup.idr-git-hooks.text = ''
        if [[ -e "$PRJ_ROOT/.git" ]]; then
          (cd "$PRJ_ROOT" && idr-with-project-lock ${pkgs.writeShellScript "pre-commit-shellhook" config.pre-commit.shellHook})
        fi
      '';
      packages = config.pre-commit.settings.enabledPackages;
    };
  };
}

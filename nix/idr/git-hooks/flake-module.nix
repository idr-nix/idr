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
    closure = pkgs.closureInfo {
      rootPaths = [settings.configFile settings.package settings.gitPackage pkgs.bash pkgs.nushell] ++ settings.enabledPackages;
    };
    install = pkgs.writeShellScript "idr-install-git-hooks" ''
      exec ${pkgs.python3}/bin/python ${./install.py} \
        ${lib.getExe settings.gitPackage} \
        ${pkgs.writeShellScript "pre-commit-shellhook" config.pre-commit.shellHook} \
        ${lib.escapeShellArg settings.configPath} ${settings.configFile} \
        ${closure}/store-paths ${./launcher.nu} ${pkgs.nushell}/bin/nu
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

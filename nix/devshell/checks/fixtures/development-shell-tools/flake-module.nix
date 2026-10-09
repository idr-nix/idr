_: {
  perSystem = {pkgs, ...}: {
    devshells.default = {
      packages = [pkgs.curl];
      devshell.startup.prepare-cache.text = "${pkgs.writers.writeNu "prepare-cache" ''
        mkdir ($env.PRJ_DATA_DIR | path join "cache")
      ''}";
      env = [
        {
          name = "APP_ENV";
          value = "development";
        }
      ];
      commands = [
        {
          name = "check-whitespace";
          help = "Check patch whitespace";
          package = pkgs.writers.writeNuBin "check-whitespace" ''
            ^${pkgs.git}/bin/git diff --check
          '';
        }
      ];
    };
  };
}

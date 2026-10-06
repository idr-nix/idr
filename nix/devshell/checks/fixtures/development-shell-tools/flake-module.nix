_: {
  perSystem = {pkgs, ...}: {
    devshells.default = {
      packages = [pkgs.curl];
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

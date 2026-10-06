_: {
  perSystem = {pkgs, ...}: {
    pre-commit = {
      settings.hooks.alejandra.enable = true;
      check.enable = true;
    };
    devshells.default.packages = [pkgs.pre-commit];
  };
}

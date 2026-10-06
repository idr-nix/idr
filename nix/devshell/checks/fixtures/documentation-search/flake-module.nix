_: {
  flake.modules.nixos.documentation-example = {lib, ...}: {
    options.services.documentationExample.greeting = lib.mkOption {
      type = lib.types.str;
      default = "Hello from the project";
      description = "Greeting shown by the documentation search example.";
    };
  };

  perSystem = {pkgs, ...}: {
    devshells.default.packages = [pkgs.fzf];
  };
}

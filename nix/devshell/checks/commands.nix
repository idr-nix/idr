{
  pkgs,
  inputs,
  self,
}: let
  inherit (pkgs) lib;
  shell = inputs.devshell.legacyPackages.${pkgs.stdenv.hostPlatform.system}.eval {
    configuration = {
      imports = [self.modules.devshell.idr];
      idr = {
        projectName = "idr-tests";
        # Each test declares its build inputs; the example machine closure is unnecessary.
        additionalPaths = lib.mkForce [];
      };
    };
  };
in {
  packages = builtins.listToAttrs (map (command: {
      inherit (command) name;
      value = command.package;
    })
    shell.config.commands);
}

top: {
  pkgs,
  lib,
  config,
  modulesPath,
  ...
}: {
  imports =
    lib.unique (
      (builtins.attrValues top.inputs.idr.modules.nixos) ++ (builtins.attrValues top.inputs.self.modules.nixos)
    )
    ++ (top.idr-lib.importApplyAll top [
      ./hardware-specific.nix
    ]);

  config = lib.mkMerge [
    # misc
    {
      hardware.facter.reportPath = lib.mkIf (builtins.pathExists ./facter.json) ./facter.json;
      networking.hostName = "example-x86_64-linux";
      system.stateVersion = "26.05";

      idr.preset.base = {
        inherit (top) inputs;
        id = "1e6f6e96b47c";
        defaultSopsFile = ./secrets.enc.json;
        preFormatFiles."/disk-key.txt" = {
          sopsFile = ./disk-key.enc.json;
          key = "disk_key";
        };
      };
    }
  ];
}

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
      networking.hostName = "example-aarch64-linux";
      system.stateVersion = "26.05";

      idr.preset.base = {
        inherit (top) inputs;
        id = "b1954bce0be0";
        defaultSopsFile = ./secrets.enc.json;
        preFormatFiles."/disk-key.txt" = {
          sopsFile = ./disk-key.enc.json;
          key = "disk_key";
        };
      };
    }
  ];
}

top: {
  config,
  hostPkgs,
  lib,
  ...
}: let
  inherit (config.idr.test) storePaths;
in {
  imports = [top.self.modules.nixosTest.disk-storage];

  options.idr.test.storePaths = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [];
    description = "Store paths whose closures are registered in each node's Nix database, so they can be used offline.";
  };

  config = {
    containerDefaults = {
      config,
      pkgs,
      ...
    }: let
      regInfo = pkgs.closureInfo {rootPaths = [config.system.build.toplevel] ++ storePaths;};
    in {
      # Share the store read-write: existing paths stay read-only mounts, new paths can be added.
      virtualisation.systemd-nspawn.options = [
        "--bind=/nix/store:/nix/store"
        "--setenv=NIX_REGINFO=${regInfo}/registration"
      ];
      boot.postBootCommands = ''
        ${config.nix.package.out}/bin/nix-store --load-db < "$NIX_REGINFO"
      '';
      # The nixbld group is not mapped in the build sandbox.
      nix.settings.build-users-group = "";
    };

    nodeDefaults.virtualisation = {
      writableStore = true;
      additionalPaths = storePaths;
      # The image restores case-sensitive names hidden by Darwin's Nix case hack.
      # A 9p mount exposes the renamed host paths directly to Linux guests.
      useNixStoreImage = lib.mkIf hostPkgs.stdenv.hostPlatform.isDarwin (lib.mkDefault true);
    };
  };
}

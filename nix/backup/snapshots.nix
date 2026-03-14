_: {
  config,
  lib,
  ...
}: let
  pools = config.disko.devices.zpool or {};
  roots =
    lib.optionals ((config.idr.preset.base.enable or false) && !config.boot.isContainer)
    (lib.attrNames pools);
in {
  config = {
    services.sanoid = {
      enable = lib.mkDefault (roots != [] || config.idr.backup.server.enable);
      interval = lib.mkDefault "*:0/5";
      datasets = lib.mkMerge [
        (lib.genAttrs roots (_: {
          use_template = lib.mkDefault ["idr_short_term"];
          recursive = lib.mkDefault true;
          autosnap = lib.mkDefault true;
          autoprune = lib.mkDefault true;
        }))
        (lib.concatMapAttrs (pool: poolConfig:
          lib.mapAttrs' (name: dataset:
            lib.nameValuePair (dataset._name or "${pool}/${name}") {
              recursive = true;
              autosnap = false;
              autoprune = false;
            }) (lib.filterAttrs (_: dataset: (dataset.options."idr:snapshots" or null) == "false") poolConfig.datasets))
        pools)
      ];
      templates = lib.mapAttrs (_: values: lib.mapAttrs (_: value: lib.mkDefault value) values) {
        idr_short_term = {
          yearly = 2;
          monthly = 2;
          weekly = 2;
          daily = 2;
          hourly = 24 * 2;
          frequent_period = 15;
          frequently = 4 * 24 * 2;
        };
        idr_long_term = {
          yearly = 256;
          monthly = 3 * 12;
          weekly = 4 * 4;
          daily = 2 * 30;
          hourly = 24 * 30;
          frequent_period = 15;
          frequently = 4 * 24 * 7;
        };
      };
    };
  };
}

_: {
  perSystem = {pkgs, ...}: {
    devshells.default.devshell.startup.prepare-cache.text = "${pkgs.writers.writeNu "prepare-cache" ''
      mkdir ($env.PRJ_DATA_DIR | path join "cache")
    ''}";
  };
}

_: {
  perSystem = {pkgs, ...}: {
    idr.files.".config/startup-message".content = "Generated before the startup action\n";

    devshells.default.devshell.startup.consume-generated-file = {
      deps = ["idr-write-files"];
      text = "${pkgs.writers.writeNu "consume-generated-file" ''
        let cache = $env.PRJ_DATA_DIR | path join "cache"
        mkdir $cache
        open --raw ($env.PRJ_ROOT | path join ".config/startup-message")
          | save --force ($cache | path join "startup-message")
      ''}";
    };
  };
}

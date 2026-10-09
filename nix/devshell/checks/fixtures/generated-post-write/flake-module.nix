_: {
  perSystem = {pkgs, ...}: {
    idr.files.".data/example-app.template.json" = {
      content = ''{"logLevel": "info"}'';
      postWrite = pkgs.writers.writeNu "render-example-config" ''
        mkdir $env.PRJ_DATA_DIR
        open ($env.PRJ_ROOT | path join ".data/example-app.template.json")
          | insert dataDir ($env.PRJ_DATA_DIR | path join "example-app")
          | to json
          | save --force ($env.PRJ_DATA_DIR | path join "example-app.json")
      '';
    };
  };
}

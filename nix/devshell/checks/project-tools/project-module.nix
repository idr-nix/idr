_: {lib, ...}: let
  roleName = "test-${(lib.importJSON ../role/test/meta.json).id}";
  otherRoleName = "test-${(lib.importJSON ../other-roles/test/meta.json).id}";
in {
  idr.roleDirs = ["nix/other-roles"];
  flake.modules.nixos.test-machine = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.networking.hostName == "test-machine") {
      idr.roles.${roleName}.enable = true;
      idr.roles.${otherRoleName}.enable = false;
    };
  };
  perSystem = {...}: {
    idr.files = {
      "generated/link.txt".content = "generated\n";
      "generated/copied.txt" = {
        content = "generated\n";
        copy = true;
        postWrite = ''printf x >> "$PRJ_DATA_DIR/generated-hooks"'';
      };
    };
  };
}

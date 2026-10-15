top: {
  lib,
  pkgs,
  config,
  idrSsh,
  idrNu,
  ...
}: let
  scripts = ../../scripts;

  idr-generate-ssh-key = pkgs.writers.makeScriptWriter {
    interpreter = "${lib.getExe idrNu} --no-config-file";
    makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.coreutils pkgs.openssh])];
  } "/bin/idr-generate-ssh-key" (builtins.readFile (scripts + /idr-generate-ssh-key.nu));

  idr-rotate-keys =
    pkgs.writers.writeNuBin "idr-rotate-keys" {
      makeWrapperArgs = [
        "--prefix"
        "PATH"
        ":"
        (lib.makeBinPath [pkgs.coreutils pkgs.gitMinimal pkgs.nix pkgs.sops pkgs.openssh pkgs.ssh-to-age pkgs.mkpasswd idr-generate-ssh-key])
      ];
    } ''
      source ${scripts}/idr-rotate-keys.nu
    '';

  idr-revoke-old-disk-keys =
    pkgs.writers.writeNuBin "idr-revoke-old-disk-keys" {
      makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.coreutils pkgs.nix idrSsh])];
    } ''
      source ${scripts}/idr-revoke-old-disk-keys.nu
    '';

  idr-age-key = pkgs.writeShellApplication {
    name = "idr-age-key";
    runtimeInputs = with pkgs; [nushell];
    text = ''
      exec nu -n --no-std-lib --no-history ${scripts}/idr-age-key.nu "$@"
    '';
  };
  idr-setup-machine = pkgs.writeShellApplication {
    name = "idr-setup-machine";
    runtimeInputs = with pkgs; [nushell mkpasswd];
    text = ''
      export IDR_PATH="${top.self}"
      exec nu -n --no-std-lib --no-history ${scripts}/idr-setup-machine.nu "$@"
    '';
  };
in {
  options.idr.team = lib.mkOption {
    description = ''
      Team information parsed from team.toml, containing member details and group memberships.
    '';
    type = lib.types.attrsOf lib.types.unspecified;
    defaultText = "<idr-flake>.lib.team";
    default = top.self.lib.team;
  };

  config = {
    env = lib.mkBefore [
      {
        name = "SOPS_AGE_KEY_CMD";
        value = "${idr-age-key}/bin/idr-age-key";
      }
      {
        name = "IDR_TEAM_JSON_FILE";
        value = pkgs.writers.writeJSON "team.json" config.idr.team;
      }
    ];
    commands = [
      {
        name = "idr-rotate-keys";
        package = idr-rotate-keys;
        help = "Rotate expired machine keys and passwords in the repository";
      }
      {
        name = "idr-revoke-old-disk-keys";
        package = idr-revoke-old-disk-keys;
        help = "Revoke old disk keys on a running machine";
      }
      {
        name = "sops";
        package = pkgs.sops;
      }
    ];
    packages = [idr-age-key idr-setup-machine pkgs.ssh-to-age];
    idr.additionalPaths = [pkgs.remarshal_0_17];
  };
}

{
  lib,
  pkgs,
  machine,
  activation,
  activateProgram ? "${activation}/activate-rs",
}: let
  identity = machine.config.environment.etc."idr-microvm-identity".source;
  guard = pkgs.writeShellScript "microvm-activate-${machine.config.networking.hostName}" ''
    if ! ${pkgs.diffutils}/bin/cmp -s /run/current-system/etc/idr-microvm-identity ${identity}; then
      printf '%s\n' ${lib.escapeShellArg "Refusing to deploy ${machine.config.networking.hostName}: the target is not this MicroVM."} >&2
      exit 1
    fi
    exec ${lib.escapeShellArg activateProgram} "$@"
  '';
in
  activation.overrideAttrs (old: {
    # deploy-rs changes the system profile before calling deploy-rs-activate.
    # Guard its entry point so SSH overrides cannot activate a guest on its host.
    postBuild =
      (old.postBuild or "")
      + ''
        rm "$out/activate-rs"
        ln -s ${guard} "$out/activate-rs"
      '';
  })

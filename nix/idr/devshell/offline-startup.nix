top: {
  lib,
  pkgs,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  names = builtins.attrNames top.self.legacyPackages.${system}.idrOfflineDependencies;
  source = import ./offline-source.nix {
    inherit lib pkgs;
    idr = top.self;
  };
in {
  devshell.startup.idr-build-deps.text = lib.optionalString (names != []) ''
    ${pkgs.nushell}/bin/nu -n --no-std-lib --no-history ${../../scripts}/idr-build-deps.nu \
      ${lib.escapeShellArgs (["${source}" system] ++ names)} || exit $?
  '';
}

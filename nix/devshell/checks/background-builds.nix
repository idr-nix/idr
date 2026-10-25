_: {...}: {
  perSystem = {
    lib,
    pkgs,
    ...
  }: {
    checks.background-builds =
      pkgs.runCommand "background-builds" {
        nativeBuildInputs = with pkgs; [nushell coreutils daemonize execline flock] ++ lib.optional stdenv.hostPlatform.isLinux procps;
      } ''
        nu -n --no-std-lib --no-history ${./fixtures/background-builds.nu} ${../../scripts/idr-build-background.nu}
        touch "$out"
      '';
  };
}

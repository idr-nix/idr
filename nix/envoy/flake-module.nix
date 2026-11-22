_: {
  perSystem = {
    lib,
    pkgs,
    ...
  }: {
    idr.packages.envoy = {
      package = pkgs.callPackage ./package.nix {};
      update = pkgs.writeShellScript "update-envoy" ''
        exec ${lib.getExe pkgs.nix-update} --flake envoy \
          --custom-dep src-x86_64-linux --custom-dep src-aarch64-linux
      '';
    };
  };

  idr.reminders.envoy-package = {
    description = ''
      Review the Envoy package after the next NixOS release.

      Once nixpkgs follows that release, check its envoy-bin. If that Envoy
      release stays supported until the NixOS release's end of life
      (https://github.com/envoyproxy/envoy/blob/main/RELEASES.md), use envoy-bin
      and remove nix/envoy/package.nix with its idr.packages entry. Otherwise
      set the interval to the following NixOS release.
    '';
    lastReviewedAt = 1795384095; # 2026-11-22 UTC
    # NixOS 26.11 is planned for 2026-11-30.
    reviewIntervalSec = 8 * 24 * 60 * 60;
  };

  idr.reminders.envoy-source = {
    description = ''
      Check whether nixpkgs' envoy, built from source, can replace the binary
      Envoy package.

      In the NixOS release nixpkgs follows, check envoy. If that Envoy release
      stays supported until the NixOS release's end of life
      (https://github.com/envoyproxy/envoy/blob/main/RELEASES.md), use envoy
      instead of the binary package.
    '';
    lastReviewedAt = 1795384095; # 2026-11-22 UTC
    reviewIntervalSec = 182 * 24 * 60 * 60;
  };
}

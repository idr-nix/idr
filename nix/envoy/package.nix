{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  versionCheckHook,
}: let
  version = "1.40.2";
  # Every system's release binary is fetched on the current one, so that
  # nix-update can update all hashes from one machine.
  sources = lib.mapAttrs (_: {
    arch,
    hash,
  }:
    fetchurl {
      url = "https://github.com/envoyproxy/envoy/releases/download/v${version}/envoy-${version}-linux-${arch}";
      inherit hash;
    }) {
    x86_64-linux = {
      arch = "x86_64";
      hash = "sha256-HWRQbiXBhE8UYWLdsuznAQ+k54T63bQKB5AhSR8fA8w=";
    };
    aarch64-linux = {
      arch = "aarch_64";
      hash = "sha256-udbR4G3Vg4o1Bt6fTe66096aLObK24fNdiIsooYhO68=";
    };
  };
  inherit (stdenvNoCC.hostPlatform) system;
in
  stdenvNoCC.mkDerivation {
    pname = "envoy";
    inherit version;
    src = sources.${system} or (throw "envoy is not available for ${system}.");

    nativeBuildInputs = [autoPatchelfHook];
    strictDeps = true;

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -D -m755 "$src" "$out/bin/envoy"
      runHook postInstall
    '';

    nativeInstallCheckInputs = [versionCheckHook];
    doInstallCheck = true;

    # src-<system> for every system, updated with nix-update --custom-dep.
    passthru = lib.mapAttrs' (system: lib.nameValuePair "src-${system}") sources;

    meta = {
      description = "Cloud-native edge and service proxy";
      homepage = "https://www.envoyproxy.io";
      changelog = "https://github.com/envoyproxy/envoy/releases/tag/v${version}";
      license = lib.licenses.asl20;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = lib.attrNames sources;
      mainProgram = "envoy";
    };
  }

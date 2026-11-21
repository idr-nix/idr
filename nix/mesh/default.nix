{
  lib,
  buildPackages,
  callPackage,
  makeWrapper,
  acl,
  getent,
  iproute2,
  iptables,
  nftables,
  procps,
  systemd,
  util-linux,
  wireguard-tools,
}: let
  haskellPackages = callPackage ./package-set.nix {};
in
  haskellPackages.mkDerivation {
    pname = "idr-mesh";
    version = "0.1.0.0";
    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [./app ./src ./Setup.hs ./idr-mesh.cabal];
    };
    isExecutable = true;
    isLibrary = false;
    doHaddock = false;
    enableSharedExecutables = false;
    enableSharedLibraries = false;
    enableLibraryProfiling = false;
    postPatch = ''
      substituteInPlace src/IDR/Mesh/Etcd/Connection.hs \
        --replace-fail /usr/bin/getent ${lib.getExe' getent "getent"}
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 dist/build/idr-mesh/idr-mesh "$out/bin/idr-mesh"
      runHook postInstall
    '';
    executableSystemDepends = [acl];
    executableHaskellDepends = with haskellPackages; [
      aeson
      async
      base
      base64-bytestring
      bytestring
      containers
      crypton
      directory
      filepath
      effectful
      effectful-core
      filelock
      grapesy
      hinotify
      http2
      iproute
      network
      network-uri
      optparse-applicative
      process
      proto-lens-etcd
      proto-lens
      memory
      random
      stm
      haskellPackages.systemd
      text
      time
      time-manager
      tls
      transformers
      unix
    ];
    executableToolDepends = [makeWrapper (lib.getBin buildPackages.haskellPackages.Agda)];
    postInstall = ''
      wrapProgram "$out/bin/idr-mesh" \
        --prefix PATH : ${lib.makeBinPath [iproute2 wireguard-tools nftables procps util-linux]} \
        --suffix PATH : ${lib.makeBinPath [iptables systemd]}
    '';
    description = "WireGuard service mesh for NixOS";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "idr-mesh";
  }

{
  lib,
  cloud-hypervisor,
  rustPlatform,
  src,
}: let
  manifest = builtins.fromTOML (builtins.readFile "${src}/cloud-hypervisor/Cargo.toml");
  date = lib.substring 0 8 src.lastModifiedDate;
  extraVersion = "unstable-${date}-${src.shortRev}";
in
  cloud-hypervisor.overrideAttrs (old: {
    version = "${manifest.package.version}-${extraVersion}";
    inherit src;

    # Registry checksums come from the upstream lock file; the Git dependency
    # hash includes its submodules, as required by importCargoLock.
    cargoDeps = rustPlatform.importCargoLock {
      lockFile = "${src}/Cargo.lock";
      outputHashes = {
        "micro_http-0.1.0" = "sha256-UTj6L1WjgWgopiAic/30KfTS/U84tuXZpJjiChCR+/k=";
      };
    };

    env = (old.env or {}) // {CH_EXTRA_VERSION = extraVersion;};

    # Physical allocation of sparse and zero-filled files depends on the host
    # filesystem; these upstream tests assume uncompressed allocation.
    cargoTestFlags =
      (old.cargoTestFlags or [])
      ++ [
        "--skip=formats::vmdk::tests::logical_and_physical_size_single_extent"
        "--skip=formats::vmdk::tests::logical_size_sums_multiple_extents"
        "--skip=formats::vmdk::tests::physical_size_matches_fully_allocated_extents"
      ];

    postInstallCheck =
      (old.postInstallCheck or "")
      + ''
        "$out/bin/ch-remote" --help | grep -- 'balloon-stats'
      '';

    passthru =
      (old.passthru or {})
      // {
        supportsBalloonStats = true;
        upstreamRevision = src.rev;
      };
    meta = old.meta // {changelog = "https://github.com/cloud-hypervisor/cloud-hypervisor/commits/${src.rev}/";};
  })

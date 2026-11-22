{
  lib,
  cloud-hypervisor,
  fetchFromGitHub,
  rustPlatform,
}:
cloud-hypervisor.overrideAttrs (finalAttrs: old: {
  version = "54.0.0-unstable-2026-10-09";
  src = fetchFromGitHub {
    owner = "cloud-hypervisor";
    repo = "cloud-hypervisor";
    rev = "36225ee3230fa263f0b03a6ba12a42b0f3ec8f91";
    hash = "sha256-oBmp25WOkhMWwxRRIwdWSNWWiLhJYyoeQ6+sKQPDmfI=";
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src;
    hash = "sha256-x02Ofq0/y1xn7CETfHIlQvtQM9RzFbMKKF72wGyl8s4=";
  };

  # --version reports the commit after the Cargo version, which differs from
  # the release this version names, so the install check looks for the commit.
  env = (old.env or {}) // {CH_EXTRA_VERSION = lib.substring 0 7 finalAttrs.src.rev;};
  dontVersionCheck = true;

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
      "$out/bin/cloud-hypervisor" --version | grep -F -- "-$CH_EXTRA_VERSION"
      "$out/bin/ch-remote" --help | grep -- 'balloon-stats'
    '';

  passthru =
    (old.passthru or {})
    // {
      supportsBalloonStats = true;
      upstreamRevision = finalAttrs.src.rev;
    };
  meta = old.meta // {changelog = "https://github.com/cloud-hypervisor/cloud-hypervisor/commits/${finalAttrs.src.rev}/";};
})

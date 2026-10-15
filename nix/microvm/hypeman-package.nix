{
  lib,
  buildGoModule,
  src,
}:
buildGoModule {
  pname = "hypeman-memory";
  version = "unstable-${src.shortRev or "source"}";
  inherit src;

  patches = [./hypeman/upstream-fixes.patch];
  vendorHash = "sha256-O/O6sms1bm91zNP+ZpY2qg9s+WAO4d1deMuCNynDn3o=";
  subPackages = ["cmd/idr-microvm-memory"];
  env.CGO_ENABLED = 0;
  ldflags = ["-s" "-w"];
  doCheck = false; # Covered by the module's NixOS end-to-end test.

  postPatch = ''
    mkdir -p cmd/idr-microvm-memory
    cp ${./hypeman/main.go} cmd/idr-microvm-memory/main.go

    # We connect to existing VMMs. The driver's unused launch helpers do not
    # need bundled hypervisor binaries; an empty embed.FS fails extraction.
    test "$(grep -c '^//go:embed binaries/cloud-hypervisor/' lib/vmm/binaries_linux.go)" = 4
    sed -i '\|^//go:embed binaries/cloud-hypervisor/|d' lib/vmm/binaries_linux.go
  '';

  meta = {
    description = "Hypeman memory controller for microvm.nix guests";
    homepage = "https://github.com/kernel/hypeman";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "idr-microvm-memory";
  };
}

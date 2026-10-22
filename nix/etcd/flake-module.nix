top: {lib, ...}: {
  flake.modules.nixos.etcd = lib.modules.importApply ./nixos-module.nix top;

  idr.reminders.etcd-proxy-cache = {
    description = ''
      Review the temporary etcd gRPC proxy KV cache workaround.
      Upstream issue: https://github.com/etcd-io/etcd/issues/22065

      Run the etcd-proxy regression test with the pinned, unpatched etcd package.
      Once the authorization and revocation cases pass, remove
      nix/etcd/grpc-proxy-disable-kv-cache.patch and its package override in
      nix/etcd/options.nix. Keep the regression tests.
    '';
    lastReviewedAt = 1792540800; # 2026-10-21 UTC
    reviewIntervalSec = 7 * 24 * 60 * 60;
  };
}

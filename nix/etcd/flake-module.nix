top: {lib, ...}: {
  flake.modules.nixos.etcd = lib.modules.importApply ./nixos-module.nix top;

  idr.reminders.etcd-proxy-cache = {
    description = ''
      Review the temporary etcd gRPC proxy KV cache workaround.
      Upstream issue: https://github.com/etcd-io/etcd/issues/22065

      Run the etcd-proxy regression test with only the KV cache patch removed.
      Once the authorization and revocation cases pass, remove
      nix/etcd/grpc-proxy-disable-kv-cache.patch and its entry in
      nix/etcd/options.nix. Keep the regression tests.
    '';
    lastReviewedAt = 1792540800; # 2026-10-21 UTC
    reviewIntervalSec = 7 * 24 * 60 * 60;
  };

  idr.reminders.etcd-proxy-lease-keepalive = {
    description = ''
      Review the temporary etcd gRPC proxy lease keepalive workaround.
      Check upstream for per-client authentication on lease keepalive streams:
      https://github.com/etcd-io/etcd/blob/main/server/proxy/grpcproxy/lease.go

      With only this patch removed, verify that an authenticated proxy client
      keeps its key alive beyond the lease TTL, unauthorized clients cannot
      renew it, and the lease expires after cancellation. Once these cases pass,
      remove nix/etcd/grpc-proxy-forward-lease-keepalive.patch and its entry in
      nix/etcd/options.nix.
    '';
    lastReviewedAt = 1792722261; # 2026-10-23 UTC
    reviewIntervalSec = 90 * 24 * 60 * 60;
  };

  idr.reminders.etcd-proxy-watch-auth = {
    description = ''
      Review the temporary etcd gRPC proxy watch authentication fix.
      Upstream PR: https://github.com/etcd-io/etcd/pull/19033

      Run the etcd-proxy regression test with only the watch authentication
      patch removed. Once watches for different users and after token expiry
      pass, remove nix/etcd/grpc-proxy-watch-auth.patch and its entry in
      nix/etcd/options.nix. Keep the regression tests.
    '';
    lastReviewedAt = 1792725574; # 2026-10-23 UTC
    reviewIntervalSec = 30 * 24 * 60 * 60;
  };
}

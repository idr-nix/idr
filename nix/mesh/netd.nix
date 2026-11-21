{meshExe}: {
  config,
  lib,
  ...
}: let
  cfg = config.idr.mesh;
in {
  config = lib.mkIf cfg.enable {
    # Workload status files. The agent watches the directory from boot.
    systemd.tmpfiles.rules = ["d /run/idr-mesh-netd 0755 root root -"];

    systemd.sockets.idr-mesh-netd = {
      description = "Mesh network daemon socket";
      wantedBy = ["sockets.target"];
      listenStreams = ["/run/idr-mesh-netd.sock"];
      # netd accepts only agent requests from callers other than root.
      socketConfig = {
        SocketGroup = "idr-mesh";
        SocketMode = "0660";
      };
    };

    # The only writer of workload namespaces, WireGuard links, ports and PSK
    # key stores. systemd starts it on demand and it exits when idle; it never
    # tears anything down on exit, so a restart on switch is harmless. It
    # publishes each up workload's key, port and PSK adverts for the agent.
    systemd.services.idr-mesh-netd = {
      description = "Mesh network daemon";
      requires = ["idr-mesh-netd.socket"];
      after = ["idr-mesh-netd.socket" "systemd-modules-load.service"];
      # A switch restarts it once removed workloads are stopped, instead of
      # stopping it and its socket alongside them, so their ctl down reaches it.
      stopIfChanged = false;
      # Port retries recognize the kernel's address-in-use error message.
      environment.LC_ALL = "C";
      serviceConfig = {
        ExecStart = "${meshExe} netd ${cfg.ipv6Prefix} ${toString (cfg.portRange.from + 1)} ${toString cfg.portRange.to}";
        CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" "CAP_SYS_ADMIN" "CAP_DAC_OVERRIDE" "CAP_DAC_READ_SEARCH"];
        NoNewPrivileges = true;
        UMask = "0077";
        # SIGTERM reaches netd alone, which finishes its requests, including their
        # ip, nsenter and wg children, before it exits.
        KillMode = "mixed";
      };
    };
  };
}

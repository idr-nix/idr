{meshExe}: {
  config,
  lib,
  utils,
  ...
}: let
  cfg = config.idr.mesh;
  directory = cfg.metrics.textfileDirectory;
in {
  options.idr.mesh.metrics.textfileDirectory = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "/var/lib/node-exporter-textfile";
    description = "Directory of node-exporter's textfile collector. The mesh writes idr-mesh.prom there every 30 seconds.";
  };

  config = lib.mkIf (cfg.enable && directory != null) {
    systemd.tmpfiles.rules = ["d ${directory} 0755 root root -"];

    systemd.services.idr-mesh-metrics = {
      description = "Mesh metrics for node-exporter";
      serviceConfig = {
        Type = "oneshot";
        # A collection that hangs must not hold off the next one.
        TimeoutStartSec = "25s";
        ExecStart = utils.escapeSystemdExecArgs [meshExe "metrics" "${directory}/idr-mesh.prom"];
        # Reads the agent's and netd's state, and the WireGuard links inside
        # workload namespaces.
        CapabilityBoundingSet = ["CAP_DAC_READ_SEARCH" "CAP_SYS_ADMIN" "CAP_NET_ADMIN"];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [directory];
      };
    };

    systemd.timers.idr-mesh-metrics = {
      description = "Write mesh metrics every 30 seconds";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnActiveSec = "1s";
        OnUnitActiveSec = "30s";
        AccuracySec = "1s";
      };
    };
  };
}

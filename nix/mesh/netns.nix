{
  setupExe,
  meshServices,
}: {
  config,
  lib,
  ...
}: let
  cfg = config.idr.mesh;
  namespaceServices = lib.mapAttrs' (name: service:
    lib.nameValuePair "idr-mesh-netns@${name}" {
      overrideStrategy = "asDropin";
      enableDefaultPath = false;
      restartTriggers = [service.id];
    })
  meshServices;
in {
  config = lib.mkIf cfg.enable {
    boot.kernelModules = ["wireguard"];
    networking.firewall.allowedUDPPortRanges = [
      {
        from = cfg.portRange.from + 1;
        to = cfg.portRange.to;
      }
    ];

    systemd.services =
      namespaceServices
      // {
        "idr-mesh-netns@" = {
          description = "Mesh network namespace for %i";
          # Wanted, not required: restarting the socket must not restart workloads.
          # Ordering after the socket keeps netd reachable until the namespace is
          # down. Not after netd itself: systemd would hold netd's activation
          # until this unit has stopped, while its ctl down waits for netd.
          wants = ["idr-mesh-netd.socket"];
          after = ["idr-mesh-netd.socket"];
          stopIfChanged = false;
          unitConfig.StopWhenUnneeded = true;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            # netd creates the keys, namespace, WireGuard link, port and declarations.
            ExecStart = "${setupExe} ctl up %i";
            ExecStopPost = "${setupExe} ctl down %i";
            CapabilityBoundingSet = "";
            NoNewPrivileges = true;
          };
        };
      };
  };
}

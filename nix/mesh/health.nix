{meshExe}: {
  config,
  lib,
  ...
}: let
  cfg = config.idr.mesh;
  port = toString cfg.portRange.from;
  # NixOS replaces the socket when its listen addresses change.
  socket = "idr-mesh-health-${port}-dual";
in {
  config = lib.mkIf cfg.enable {
    networking.firewall.allowedUDPPorts = [cfg.portRange.from];

    systemd.sockets.${socket} = {
      description = "Mesh UDP health listener";
      aliases = ["idr-mesh-health.socket"];
      wantedBy = ["sockets.target"];
      listenDatagrams = ["0.0.0.0:${port}" "[::]:${port}"];
      socketConfig = {
        Service = "idr-mesh-health.service";
        BindIPv6Only = "ipv6-only";
        PassPacketInfo = true;
      };
    };

    # Answers probes on the passed sockets only. It is independent of the agent,
    # so an agent restart does not make other hosts move their endpoints.
    systemd.services.idr-mesh-health = {
      description = "Mesh UDP health responder";
      requires = ["${socket}.socket"];
      after = ["${socket}.socket"];
      stopIfChanged = false;
      serviceConfig = {
        ExecStart = "${meshExe} health";
        DynamicUser = true;
        PrivateNetwork = true;
        Restart = "on-failure";
        RestartSec = "1s";
      };
    };
  };
}

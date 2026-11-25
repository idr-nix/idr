{
  meshExe,
  meshEtcd,
}: {
  config,
  lib,
  options,
  pkgs,
  utils,
  ...
}: let
  cfg = config.idr.mesh;
  port = toString cfg.portRange.from;
  # Journals and instance IDs. A dynamic user's state lives below /var/lib/private.
  state = ["idr-mesh-agent"];
  private = map (name: "/var/lib/private/${name}") state;
in {
  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.optionalAttrs (options.environment ? persistence) {
      environment.persistence = lib.mkIf (config.idr.preset.impermanence.enable or false) {
        ${config.idr.preset.impermanence.persistDir or "/persist"}.directories =
          map (directory: {
            inherit directory;
            user = "root";
            group = "root";
            mode = "0700";
          })
          private;
      };
    })
    {
      # netd accepts the agent's requests from this group.
      users.groups.idr-mesh = {};

      systemd.sockets.idr-mesh-agent = {
        description = "Mesh host network notifications";
        wantedBy = ["sockets.target"];
        socketConfig = {
          # Link, IPv4/IPv6 address, route and rule groups, plus RTNLGRP_NEXTHOP.
          ListenNetlink = "route 2147747281";
          TriggerLimitIntervalSec = 0;
        };
      };

      # Collects the host's transport addresses, registers every up workload,
      # discovers its peers, probes their health and retires removed workloads.
      # It asks netd for the privileged work.
      systemd.services.idr-mesh-agent = {
        description = "Mesh agent";
        wantedBy = ["multi-user.target"];
        requires = ["idr-mesh-agent.socket"];
        wants = ["network-online.target" "idr-mesh-netd.socket"] ++ meshEtcd.restartTargets;
        after = ["network-online.target" "idr-mesh-agent.socket" "idr-mesh-netd.socket"] ++ meshEtcd.restartTargets;
        partOf = meshEtcd.restartTargets;
        # A changed inventory reloads the agent, which reconciles its workloads.
        reloadTriggers = [config.environment.etc."idr-mesh/services.json".source];
        unitConfig = {
          RequiresMountsFor = private;
          StartLimitIntervalSec = 0;
        };
        serviceConfig = {
          Type = "exec";
          # %d is the directory of the clusters' passwords.
          ExecStart =
            utils.escapeSystemdExecArgs (
              [meshExe "agent"]
              ++ lib.concatMap (address: ["--public-address" address]) cfg.publicAddresses
              ++ [port meshEtcd.clusters]
            )
            + " %d";
          ExecReload = "${lib.getExe' pkgs.coreutils "kill"} -HUP $MAINPID";
          # A stopped agent holds no registration, however it stopped.
          ExecStopPost = "${lib.getExe' pkgs.coreutils "rm"} -rf /run/idr-mesh-agent/registered";
          Restart = "always";
          RestartSec = "5s";
          DynamicUser = true;
          SupplementaryGroups = ["idr-mesh"];
          StateDirectory = state;
          StateDirectoryMode = "0700";
          RuntimeDirectory = ["idr-mesh-agent" "idr-mesh-addresses"];
          RuntimeDirectoryMode = "0755";
          # Retained discovery snapshots keep peers usable while etcd is
          # unreachable, also across a stop and start of the agent.
          RuntimeDirectoryPreserve = true;
          LoadCredential = meshEtcd.credentials;
          CapabilityBoundingSet = "";
          ProtectHome = true;
          UMask = "0077";
        };
      };
    }
  ]);
}

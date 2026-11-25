{
  setupExe,
  meshServices,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.idr.mesh;
  # Each peer that a service declares in another cluster.
  declarations = lib.concatLists (lib.mapAttrsToList (name: service:
    lib.mapAttrsToList (peer: link: {inherit name peer link;}) service.links)
  meshServices);
  # The link's other end declared back, by the peer service of this machine.
  back = entry: let
    service = meshServices.${entry.name};
    other = meshServices.${entry.link.workload}.links.${service.id} or null;
  in
    if entry.link.workload != null && other != null && other.cluster == service.cluster && other.workload == entry.name
    then other
    else null;
  valid = entry: back entry != null;
  invalid = lib.filter (entry: !(valid entry)) declarations;
  # Both ends list the same routes, each a peer of exactly one end in its
  # cluster, which forwards it for the other. The other end has no peer or
  # link with its ID, and reaches it through no other link.
  routesValid = entry: let
    service = meshServices.${entry.name};
    other = meshServices.${entry.link.workload};
    set = routes: lib.sort lib.lessThan (lib.unique routes);
  in
    set entry.link.routes
    == set (back entry).routes
    && lib.all (route: (service.peers ? ${route}) != (other.peers ? ${route})) entry.link.routes
    && lib.all (route: !(service.links ? ${route})) entry.link.reaches;
  misrouted = lib.filter (entry: !(routesValid entry)) (lib.filter valid declarations);
  reachedTwice = lib.filterAttrs (_: service: !(lib.allUnique (lib.concatMap (link: link.reaches) (lib.attrValues service.links)))) meshServices;
  routing = lib.any (entry: entry.link.routes != []) declarations;
  pairs = lib.unique (map (entry: lib.sort lib.lessThan [entry.name entry.link.workload]) (lib.filter valid declarations));
  links = lib.listToAttrs (map (pair: let
    hash = builtins.hashString "sha256" (builtins.toJSON pair);
    end = name: other: {
      service = name;
      inherit (meshServices.${name}) id ipv6Prefix;
      # The routes this end reaches through the other.
      inherit (meshServices.${name}.links.${meshServices.${other}.id}) reaches;
    };
  in
    lib.nameValuePair (builtins.substring 0 16 hash) {
      inherit pair;
      profile = pkgs.writeText "idr-mesh-link-${hash}.json" (builtins.toJSON {
        alias = "idr-mesh-link-${hash}";
        ends = [(end (lib.elemAt pair 0) (lib.elemAt pair 1)) (end (lib.elemAt pair 1) (lib.elemAt pair 0))];
      });
    })
  pairs);
  # Either workload's namespace starts the link, which waits for the other's.
  # A workload does not depend on its links, so adding or changing one leaves
  # it running.
  linkServices = lib.mapAttrs' (short: link: let
    namespaces = map (name: "idr-mesh-netns@${name}.service") link.pair;
    command = action: "${setupExe} link ${action} ${link.profile}";
  in
    lib.nameValuePair "idr-mesh-link-${short}" {
      description = "Mesh link between ${lib.concatStringsSep " and " link.pair}";
      wantedBy = ["multi-user.target"] ++ namespaces;
      after = namespaces;
      partOf = namespaces;
      before = map (name: "${name}.service") link.pair;
      unitConfig.ConditionPathExists = map (name: "/run/idr-mesh-netns/${name}/namespace") link.pair;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = command "create";
        ExecStopPost = command "remove";
        CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_SYS_ADMIN" "CAP_DAC_OVERRIDE"];
        NoNewPrivileges = true;
        UMask = "0077";
      };
    })
  links;
in {
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = invalid == [];
        message =
          "A mesh peer in another cluster must be the only service of this machine with that ID in that cluster, and declare the service back: "
          + lib.concatMapStringsSep ", " (entry: "${entry.name} declares ${entry.peer} in ${entry.link.cluster}") invalid
          + ".";
      }
      {
        assertion = misrouted == [] && reachedTwice == {};
        message =
          "Both services of a link must list the same routes, each a peer of exactly one of them in its cluster and reached by the other through no other peer or link: "
          + lib.concatStringsSep ", " (map (entry: "${entry.name} and ${entry.link.workload}") misrouted ++ lib.attrNames reachedTwice)
          + ".";
      }
      {
        assertion = !routing || lib.versionAtLeast config.boot.kernelPackages.kernel.version "6.17";
        message = "Routes through linked mesh peers need Linux 6.17 or later, for per-interface IPv6 forwarding.";
      }
    ];
    systemd.services = linkServices;
  };
}

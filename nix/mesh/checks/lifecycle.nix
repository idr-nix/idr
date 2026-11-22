top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.mesh-lifecycle = pkgs.testers.runNixOSTest ({
      config,
      meshFixture,
      ...
    }: let
      service = args:
        lib.recursiveUpdate (meshFixture.mkService args) {
          systemd.service.wantedBy = ["multi-user.target"];
        };
      client = id: peers:
        service {
          inherit id peers;
          body = "alpha";
        };
      replica = service {
        id = "333333333333";
        peers = ["222222222222" "333333333333"];
        body = "replica";
      };
      backend = clientId:
        service {
          id = "333333333333";
          peers = [clientId "333333333333"];
          body = "beta";
        };
      renamed = lib.mapAttrs (_: machine: machine.specialisation.rename-client.configuration) config.nodes;
      droppedClient = config.nodes.beta.specialisation.drops-client.configuration;
      keeper = clientId:
        service {
          id = "444444444444";
          peers = [clientId];
          body = "keeper";
        };
    in {
      imports = [(lib.modules.importApply ./fixture.nix {inherit top;})];
      name = "mesh-lifecycle";
      globalTimeout = 15 * 60;
      defaults = {
        virtualisation = {
          memorySize = lib.mkForce 2048;
          writableStore = true;
        };
        idr.mesh.metrics.textfileDirectory = "/var/lib/node-exporter-textfile";
      };
      nodes.alpha = {
        system.services = {
          app = {
            idr.mesh.peers."444444444444".psk = meshFixture.secret "psk";
            systemd.service.wantedBy = ["multi-user.target"];
          };
          inherit replica;
        };
        specialisation = {
          # alpha as the RBAC host, deployed for a change that removes beta's
          # client peer before beta is.
          beta-drops-client.configuration = {config, ...}: {
            idr.etcd.clusters.main.rbac = let
              derived = meshFixture.rbac {
                alpha = config;
                beta = droppedClient;
              };
            in {
              roles = lib.mkForce derived.roles;
              users = lib.mkForce derived.users;
            };
          };
          revoke.configuration.system.services = lib.mkForce {
            app = client "222222222222" ["333333333333"];
            inherit replica;
          };
          disable-replica.configuration = {
            system.services.replica.systemd.service.enable = false;
            # Changes netd in the same switch, as a package update does.
            systemd.services.idr-mesh-netd.environment.IDR_MESH_TEST_GENERATION = "disable-replica";
          };
          # alpha is also the RBAC host, so the rename deploys the roles derived
          # from both machines' renamed configurations.
          rename-client.configuration = {
            system.services = lib.mkForce {
              app = client "555555555555" ["333333333333" "444444444444"];
            };
            idr.etcd.clusters.main.rbac = let
              derived = meshFixture.rbac renamed;
            in {
              roles = lib.mkForce derived.roles;
              users = lib.mkForce derived.users;
            };
          };
        };
      };
      nodes.beta = {
        system.services = {
          app = {
            idr.mesh.peers."333333333333".psk = meshFixture.secret "psk";
            systemd.service.wantedBy = ["multi-user.target"];
          };
          keeper = keeper "222222222222";
        };
        specialisation = {
          rename-client.configuration.system.services = lib.mkForce {
            app = backend "555555555555";
            keeper = keeper "555555555555";
          };
          no-mesh.configuration = {
            system.services = lib.mkForce {};
            idr.mesh.enable = lib.mkForce false;
          };
          # Never deployed; it only describes beta after that change.
          drops-client.configuration.system.services = {
            app.idr.mesh.peers = lib.mkForce {"333333333333".psk = meshFixture.secret "psk";};
            keeper.idr.mesh.peers = lib.mkForce {};
          };
        };
      };

      testScript =
        meshFixture.script
        + ''
          import base64
          import ipaddress


          def live_records():
              records = []
              for item in registrations().get("kvs", []):
                  key = base64.b64decode(item["key"]).decode()
                  if "/instances/" not in key:
                      continue
                  service_id, instance_id = key.removeprefix(scope).split("/instances/")
                  suffix = service_id + instance_id
                  records.append({
                      **json.loads(base64.b64decode(item["value"])),
                      "service_id": service_id,
                      "instance_id": instance_id,
                      "address": str(ipaddress.IPv6Address(
                          mesh_prefix + ":" + ":".join(suffix[index:index + 4] for index in range(0, 20, 4))
                      )),
                  })
              return records

          def registration(machine, service="app"):
              key = machine.succeed(f"cat /run/idr-mesh-keys/{service}/public-key").strip()
              matches = [record for record in live_records() if record["publicKey"] == key]
              assert len(matches) == 1, matches
              return matches[0]

          def wait_records(count, absent=frozenset(), timeout=60):
              def ready(_):
                  records = live_records()
                  return len(records) == count and absent.isdisjoint(r["publicKey"] for r in records)
              retry(ready, timeout_seconds=timeout)

          def dns_answers(machine, service_id, service="app"):
              status, output = machine.execute(inside(f"getent ahostsv6 {service_id}.mesh", service))
              assert status in (0, 2), output
              return {str(ipaddress.IPv6Address(line.split()[0])) for line in output.splitlines()}

          def expect_dns(machine, service_id, addresses, service="app"):
              retry(lambda _: dns_answers(machine, service_id, service) == set(addresses), timeout_seconds=60)

          def expect_response(machine, target, body, service="app"):
              machine.wait_until_succeeds(request(target, service) + f" | grep -Fx '{body}'", timeout=90)

          def peer_keys(machine, service="app"):
              return set(machine.succeed(f"ip netns exec idr-mesh-{service} wg show idr-mesh peers").split())

          def invocation(machine, unit):
              return machine.succeed(f"systemctl show {unit}.service --property=InvocationID --value").strip()

          def expect_clean_state(machine, services):
              def clean(_):
                  for service in services:
                      status = json.loads(machine.succeed(f"jq -c .state /run/idr-mesh-apply/{service}/psk.json 2>/dev/null || echo '[]'"))
                      if any(entry["installed"] != entry["agreed"] for entry in status):
                          return False
                      if {entry["publicKey"] for entry in status} != peer_keys(machine, service):
                          return False
                  return True
              retry(clean, timeout_seconds=60)

          def deploy(machine, generation):
              machine.succeed(f"/run/booted-system/specialisation/{generation}/bin/switch-to-configuration test", timeout=180)

          setup_mesh()
          for machine, name in [(alpha, "replica"), (beta, "keeper")]:
              machine.wait_for_unit(f"{name}.service")
              wait_registered(machine, name)
          wait_records(4)

          with subtest("allocate independent replicas and the first free UDP ports during concurrent startup"):
              records = live_records()
              replicas = [record for record in records if record["service_id"] == "333333333333"]
              assert len(replicas) == 2
              assert len({record["instance_id"] for record in replicas}) == 2
              assert len({record["publicKey"] for record in records}) == 4
              for host in ["192.168.1.1", "192.168.1.2"]:
                  assert {record["port"] for record in records if host in record["publicAddresses"]} == {30001, 30002}
              expect_dns(alpha, "333333333333", [record["address"] for record in replicas])
              local_replica = registration(alpha, "replica")
              remote_replica = registration(beta)
              expect_response(alpha, local_replica["address"], "replica")
              expect_response(alpha, remote_replica["address"], "beta")
              expect_dns(alpha, "333333333333", [remote_replica["address"]], "replica")
              expect_dns(beta, "333333333333", [local_replica["address"]])
              expect_response(alpha, "beta", "beta", "replica")
              expect_response(beta, "333333333333", "replica")
              expect_dns(alpha, "444444444444", [], "replica")
              expect_response(alpha, "444444444444", "keeper")
              expect_clean_state(alpha, ["app", "replica"])
              expect_clean_state(beta, ["app", "keeper"])

          with subtest("report each workload's mesh state to operators and node-exporter"):
              def settled(_):
                  state = json.loads(alpha.succeed("idr-mesh status"))
                  workloads = state["workloads"]
                  return set(workloads) == {"app", "replica"} and bool(state["publicAddresses"]) and all(
                      w["up"]
                      and w["instance"] == registration(alpha, name)["instance_id"]
                      and w["discoveredRevision"] == w["appliedRevision"]
                      and w["pskMismatches"] == 0
                      and w["wireguard"]["peers"] > 0
                      and w["wireguard"]["recentHandshakes"] == w["wireguard"]["peers"]
                      for name, w in workloads.items()
                  )
              retry(settled, timeout_seconds=60)
              metrics = "/var/lib/node-exporter-textfile/idr-mesh.prom"
              alpha.wait_until_succeeds(
                  f"grep -Fx 'idr_mesh_workload_registered{{workload=\"app\",service=\"222222222222\"}} 1' {metrics}",
                  timeout=60,
              )
              alpha.succeed(f"grep -Fx 'idr_mesh_psk_mismatches{{workload=\"replica\",service=\"333333333333\"}} 0' {metrics}")

          with subtest("restart registration without changing the live namespace or instance"):
              before = registration(beta)
              app_invocation = invocation(beta, "app")
              namespace_invocation = invocation(beta, "idr-mesh-netns@app")
              beta.succeed("systemctl restart idr-mesh-agent.service")
              wait_registered(beta)
              assert registration(beta) == before
              assert invocation(beta, "app") == app_invocation
              assert invocation(beta, "idr-mesh-netns@app") == namespace_invocation
              assert alpha.succeed(request(before["address"])).strip() == "beta"
              beta.succeed("systemctl restart app.service")
              beta.wait_for_unit("app.service")
              wait_registered(beta)
              assert registration(beta) == before
              assert invocation(beta, "idr-mesh-netns@app") == namespace_invocation
              expect_response(alpha, before["address"], "beta")

          with subtest("rewrite state of another release without retiring or recreating the workload"):
              before = registration(beta)
              namespace = invocation(beta, "idr-mesh-netns@app")
              versioned = "/run/idr-mesh-netd/*.json /run/idr-mesh-apply/*/*.json /run/idr-mesh-agent/peers/*.json"
              # As after switching to a release with other state formats, for example a rollback.
              beta.succeed(
                  "systemctl stop idr-mesh-agent.service idr-mesh-netd.service",
                  f"for f in {versioned}; do jq '.version = 2' \"$f\" > /tmp/state && cat /tmp/state > \"$f\"; done",
                  "systemctl start idr-mesh-agent.service idr-mesh-netd.service",
              )
              beta.wait_until_succeeds(f"jq -se 'all(.version == 1)' {versioned}", timeout=60)
              wait_registered(beta)
              assert registration(beta) == before
              assert invocation(beta, "idr-mesh-netns@app") == namespace
              beta.succeed("! ls /var/lib/idr-mesh-agent/app/registrations | grep -q retiring")
              expect_response(alpha, before["address"], "beta")

          with subtest("replace rebooted instances and withdraw their previous identities"):
              previous_keys = {registration(beta, name)["publicKey"] for name in ["app", "keeper"]}
              alpha_invocation = invocation(alpha, "app")
              # As after netd exits while idle.
              beta.succeed("systemctl stop idr-mesh-netd.service")
              beta.reboot()
              beta.wait_for_shutdown()
              beta.start()
              for name in ["app", "keeper"]:
                  beta.wait_for_unit(f"{name}.service")
                  wait_registered(beta, name)
              wait_records(4, previous_keys, timeout=90)
              assert "Failed with result" not in beta.succeed("journalctl -b -1 -o cat -u 'idr-mesh-netns@*'")
              current_beta = registration(beta)
              expect_dns(alpha, "333333333333", [registration(alpha, "replica")["address"], current_beta["address"]])
              expect_dns(alpha, "444444444444", [registration(beta, "keeper")["address"]])
              expect_response(alpha, current_beta["address"], "beta")
              expect_response(alpha, "444444444444", "keeper")
              retry(lambda _: previous_keys.isdisjoint(peer_keys(alpha)), timeout_seconds=60)
              assert invocation(alpha, "app") == alpha_invocation
              expect_clean_state(alpha, ["app", "replica"])
              expect_clean_state(beta, ["app", "keeper"])

          with subtest("drop a stopped instance from its peers and give it its address back when it starts"):
              stopped = registration(beta)
              replica = registration(alpha, "replica")["address"]
              beta.succeed("systemctl stop app.service")
              def down(_):
                  app = json.loads(beta.succeed("idr-mesh status"))["workloads"]["app"]
                  return not app["up"] and app["pskMismatches"] is None
              retry(down, timeout_seconds=30)
              # Its service stays configured, yet peers stop resolving and routing to it.
              expect_dns(alpha, "333333333333", [replica])
              retry(lambda _: stopped["publicKey"] not in peer_keys(alpha), timeout_seconds=60)
              beta.succeed("systemctl start app.service")
              wait_registered(beta)
              started = registration(beta)
              assert started["address"] == stopped["address"]
              assert started["publicKey"] != stopped["publicKey"]
              expect_dns(alpha, "333333333333", [replica, started["address"]])
              expect_response(alpha, started["address"], "beta")

          with subtest("keep the peers of a service the agent may no longer read until access returns"):
              beta_etcd = etcd + "--user=mesh-beta:public-test-mesh-beta "
              present = (
                  "jq '.state.peers[] | select(.serviceId == \"222222222222\") | .registrationPresent' "
                  + "/run/idr-mesh-agent/peers/app.json | grep -Fx "
              )
              beta.wait_until_succeeds(present + "true")
              deploy(alpha, "beta-drops-client")
              beta.wait_until_fails(beta_etcd + f"get {scope}222222222222/ --prefix")
              # As after a reboot or a rollback, beta's agent starts again.
              beta.succeed("systemctl restart idr-mesh-agent.service")
              beta.wait_until_succeeds(
                  "journalctl -u idr-mesh-agent.service --grep 'No etcd access to mesh services 222222222222'"
              )
              beta.wait_until_succeeds(present + "false")
              assert beta.succeed(request("alpha")).strip() == "alpha"
              alpha.succeed("/run/booted-system/bin/switch-to-configuration test", timeout=180)
              beta.wait_until_succeeds(present + "true", timeout=60)
              assert beta.succeed(request("alpha")).strip() == "alpha"

          with subtest("apply one-sided revocation on both peers without restarting unrelated traffic"):
              keeper_record = registration(beta, "keeper")
              invocations = {(machine.name, unit): invocation(machine, unit) for machine in [alpha, beta] for unit in ["app"]}
              replica_invocation = invocation(alpha, "replica")
              deploy(alpha, "revoke")
              expect_dns(alpha, "444444444444", [])
              expect_dns(beta, "222222222222", [], "keeper")
              retry(lambda _: keeper_record["publicKey"] not in peer_keys(alpha) and not peer_keys(beta, "keeper"), timeout_seconds=60)
              alpha.fail(request(keeper_record["address"]))
              assert alpha.succeed(request("beta", "replica")).strip() == "beta"
              assert beta.succeed(request("alpha")).strip() == "alpha"
              for machine in [alpha, beta]:
                  for unit in ["app"]:
                      assert invocation(machine, unit) == invocations[(machine.name, unit)]
              assert invocation(alpha, "replica") == replica_invocation
              expect_clean_state(alpha, ["app", "replica"])
              expect_clean_state(beta, ["app", "keeper"])

          with subtest("retire a disabled replica while keeping the remaining backend and application active"):
              removed = registration(alpha, "replica")
              alpha.succeed("systemctl stop idr-mesh-netd.service")
              deploy(alpha, "disable-replica")
              alpha.succeed(
                  "test -f /etc/idr-mesh/settings/replica.json",
                  "systemctl show replica.service --property=LoadState --value | grep -Fx masked",
              )
              wait_records(3, {removed["publicKey"]})
              alpha.wait_until_fails("systemctl is-active replica.service")
              alpha.wait_until_succeeds("test ! -e /run/netns/idr-mesh-replica")
              expect_dns(alpha, "333333333333", [registration(beta)["address"]])
              expect_dns(beta, "333333333333", [])
              retry(lambda _: removed["publicKey"] not in peer_keys(alpha) | peer_keys(beta), timeout_seconds=60)
              alpha.wait_until_succeeds("test ! -e /var/lib/idr-mesh-psk/replica")
              expect_clean_state(alpha, ["app"])
              expect_clean_state(beta, ["app", "keeper"])
              assert alpha.succeed(request("beta")).strip() == "beta"
              expect_response(alpha, "444444444444", "keeper")
              for machine in [alpha, beta]:
                  for unit in ["app"]:
                      assert invocation(machine, unit) == invocations[(machine.name, unit)]

          with subtest("recreate only the changed service namespace when its service ID changes"):
              old_record = registration(alpha)
              old_namespace = invocation(alpha, "idr-mesh-netns@app")
              beta_keeper = invocation(beta, "keeper")
              deploy(beta, "rename-client")
              deploy(alpha, "rename-client")
              alpha.wait_for_unit("app.service")
              # The agent re-registers when it sees the new declaration, and again
              # with the new port once netd has recreated the namespace.
              def renamed(_):
                  records = live_records()
                  return all(r["service_id"] != "222222222222" for r in records) and any(
                      r["service_id"] == "555555555555" and r["port"] == 30001 for r in records
                  )
              retry(renamed, timeout_seconds=60)
              changed = registration(alpha)
              assert changed["service_id"] == "555555555555"
              assert changed["address"] != old_record["address"]
              assert changed["port"] == 30001
              assert invocation(alpha, "idr-mesh-netns@app") != old_namespace
              assert invocation(alpha, "app") != invocations[("alpha", "app")]
              assert invocation(beta, "app") == invocations[("beta", "app")]
              assert invocation(beta, "keeper") == beta_keeper
              expect_dns(beta, "222222222222", [])
              expect_dns(beta, "555555555555", [changed["address"]])
              expect_response(alpha, "beta", "beta")
              expect_response(alpha, "444444444444", "keeper")
              expect_response(beta, "555555555555", "alpha")
              expect_clean_state(alpha, ["app"])
              expect_clean_state(beta, ["app", "keeper"])
              # The roles change with the same deployment, so the old identity is
              # retired with or without a marker; either way nothing stays pending.
              alpha.wait_until_succeeds("! ls /var/lib/idr-mesh-agent/app/registrations | grep -q retiring")

          with subtest("follow the mesh to another etcd cluster"):
              # beta's agent misses the move, so alpha keeps beta's instances from the
              # old cluster as absent until beta registers them again.
              beta.succeed("systemctl stop idr-mesh-agent.service")
              assert json.loads(beta.succeed("idr-mesh status"))["workloads"]["app"]["instance"] is None
              # alpha's member starts over as a new cluster, as after replacing it.
              dropin = "/run/systemd/system/idr-etcd-main@alpha.service.d"
              alpha.succeed(
                  "systemctl stop idr-etcd-main@alpha.service",
                  "rm -rf /var/lib/private/idr-etcd-main@alpha/member",
                  f"mkdir -p {dropin}",
                  f"printf '[Service]\\nEnvironment=ETCD_INITIAL_CLUSTER_TOKEN=public-mesh-test-new\\n' > {dropin}/new.conf",
                  "systemctl daemon-reload",
                  "systemctl start idr-etcd-main@alpha.service",
                  "systemctl restart idr-etcd-rbac-main.service",
              )
              alpha.wait_until_succeeds(
                  "jq -e '.state.self.registrationPresent and (.state.peers | length == 2 and all(.registrationPresent | not))' "
                  "/run/idr-mesh-agent/peers/app.json",
                  timeout=90,
              )
              # The peers carried over from the old cluster still load after a restart.
              alpha.succeed("systemctl restart idr-mesh-agent.service")
              wait_registered(alpha)
              agent = alpha.succeed("systemctl show idr-mesh-agent.service --property=InvocationID --value").strip()
              alpha.fail(f"journalctl _SYSTEMD_INVOCATION_ID={agent} -o cat | grep -F 'peers/app.json: ignored'")
              expect_response(alpha, "beta", "beta")
              beta.succeed("systemctl start idr-mesh-agent.service")
              wait_records(3, timeout=90)
              # Claims in the old cluster are given up, not retried.
              for machine in [alpha, beta]:
                  machine.wait_until_succeeds("! ls /var/lib/idr-mesh-agent/*/registrations | grep -q retiring", timeout=60)
              assert registration(alpha)["address"] == changed["address"]
              expect_response(alpha, "beta", "beta")
              expect_response(alpha, "444444444444", "keeper")
              expect_response(beta, "555555555555", "alpha")

          with subtest("follow an etcd cluster restored to an older revision"):
              # The same cluster starts over, as after restoring an older backup.
              alpha.succeed(
                  "systemctl stop idr-etcd-main@alpha.service",
                  "rm -rf /var/lib/private/idr-etcd-main@alpha/member",
                  "systemctl start idr-etcd-main@alpha.service",
                  "systemctl restart idr-etcd-rbac-main.service",
              )
              def caught_up(_):
                  current = json.loads(alpha.succeed(admin + "endpoint status --write-out=json"))[0]["Status"]["header"]["revision"]
                  return all(
                      json.loads(machine.succeed("cat /run/idr-mesh-agent/peers/app.json"))["state"]["revision"] <= current
                      for machine in [alpha, beta]
                  )
              retry(caught_up, timeout_seconds=90)
              wait_records(3, timeout=90)
              expect_response(alpha, "beta", "beta")
              expect_response(beta, "555555555555", "alpha")

          with subtest("remove the mesh from a machine without failing the switch"):
              # As after netd exits while idle.
              beta.succeed("systemctl stop idr-mesh-netd.service")
              deploy(beta, "no-mesh")
              beta.fail("systemctl list-units --failed --plain --no-legend | grep -F idr-mesh")
        '';
    });
  };
}

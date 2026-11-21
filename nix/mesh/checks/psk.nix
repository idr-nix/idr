top: {lib, ...}: {
  perSystem = {pkgs, ...}: let
    fixture = settings: lib.modules.importApply ./fixture.nix ({inherit top;} // settings);
    newPsk = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=";
    nextPsk = "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=";
    traffic = pkgs.writers.writeNu "mesh-test-traffic" ''
      def --wrapped main [command: string, ...args: string] {
        $env.PATH = "${lib.makeBinPath [pkgs.util-linux pkgs.coreutils pkgs.curl]}" | split row (char esep)
        loop {
          let result = run-external $command ...$args | complete
          if $result.exit_code != 0 {
            error make {msg: $"Mesh test traffic failed: ($result.stderr | str trim)"}
          }
          sleep 1sec
        }
      }
    '';
    helpers = meshFixture: let
      keyFiles = lib.mapAttrs (name: value: toString (pkgs.writeText "mesh-test-psk-${name}" value)) {
        old = meshFixture.psk;
        new = newPsk;
        next = nextPsk;
      };
    in ''
      import base64
      import hashlib

      keys = {"old": initial_psk, "new": "${newPsk}", "next": "${nextPsk}"}
      hashes = {name: hashlib.sha256(base64.b64decode(key)).hexdigest() for name, key in keys.items()}
      key_files = json.loads('${builtins.toJSON keyFiles}')
      # Apply reports each connection's installed, wanted and agreed key hashes.
      state_command = "jq -e '.state | if length == 1 then .[0] else error(\"expected one connection\") end' /run/idr-mesh-apply/app/psk.json"
      handshake_command = "ip netns exec idr-mesh-app wg show idr-mesh latest-handshakes | cut -f2"

      def latest_handshake(machine):
          return int(machine.succeed(handshake_command))

      def wait_handshake(machine, previous):
          machine.wait_until_succeeds(f"test $({handshake_command}) -gt {previous}", timeout=180)

      def deploy(machine, key, secret="psk"):
          machine.succeed(
              f"install -m 0400 {key_files[key]} /run/mesh-test-secrets/{secret}",
              "systemctl restart mesh-test-secrets.target",
          )
          machine.wait_until_succeeds(state_command + f" | jq -e '.wanted == \"{hashes[key]}\"'", timeout=60)

      def kernel_hash(machine):
          return machine.succeed(
              "ip netns exec idr-mesh-app wg show idr-mesh preshared-keys | "
              "cut -f2 | base64 --decode | sha256sum | cut -d' ' -f1"
          ).strip()

      # An installed key changes only early in a session, so a switch can wait
      # for the next handshake, about two minutes after the last one.
      def wait_state(machine, installed, wanted=None, timeout=180):
          wanted = installed if wanted is None else wanted
          machine.wait_until_succeeds(
              state_command + f" | jq -e '.installed == \"{hashes[installed]}\" and .wanted == \"{hashes[wanted]}\"'",
              timeout=timeout,
          )
          assert kernel_hash(machine) == hashes[installed]

      def advert(name):
          entries = json.loads(alpha.succeed(
              admin + f"get {scope}{instances[name]['id']}/instances/ --prefix --write-out=json"
          )).get("kvs", [])
          if len(entries) != 1:
              return None
          peers = json.loads(base64.b64decode(entries[0]["value"]))["peers"]
          return peers[instances[instances[name]["peer"]]["id"]]

      def wait_advert(name, wanted, held=()):
          expected = {"pskHash": hashes[wanted]} | ({"held": sorted(hashes[k] for k in held)} if held else {})
          retry(lambda _: advert(name) == expected, timeout_seconds=60)

      # Rotation is finished when no registration holds an old key and every key
      # store keeps only the configured one.
      def wait_clean():
          for name, machine in members.items():
              wait_mesh_idle(machine)
              retry(lambda _: advert(name) is not None and "held" not in advert(name), timeout_seconds=60)
              machine.wait_until_succeeds("jq -se 'all(.state | length == 1)' /var/lib/idr-mesh-psk/app/[0-9a-f]*.json")

      def cut_from_etcd(machine):
          machine.succeed(
              "nft add table inet mesh_test_outage",
              "nft 'add chain inet mesh_test_outage output { type filter hook output priority -50; policy accept; }'",
              "nft add rule inet mesh_test_outage output ip daddr 192.168.1.1 tcp dport 2379 drop",
          )
          name = next(n for n, m in members.items() if m is machine)
          retry(lambda _: advert(name) is None, timeout_seconds=60)

      def restore_etcd(machine):
          machine.succeed("nft delete table inet mesh_test_outage")
    '';
    recoveryTest = {
      name,
      target,
    }:
      pkgs.testers.runNixOSTest ({meshFixture, ...}: {
        imports = [(fixture {})];
        inherit name;
        nodes.beta = {
          system.services.app.idr.mesh.peers.${meshFixture.instances.alpha.id}.psk = lib.mkForce (meshFixture.secret "other-psk");
          systemd.tmpfiles.rules = [
            "C /run/mesh-test-secrets/other-psk 0400 root root - ${pkgs.writeText "mesh-test-other-psk" newPsk}"
          ];
        };
        testScript =
          meshFixture.script
          + helpers meshFixture
          + ''
            setup_mesh()
            wait_state(alpha, "old")
            wait_state(beta, "new")
            alpha.fail(request("beta"))
            beta.fail(request("alpha"))

            with subtest("agree on a key as soon as both ends hold it, ${
              if target == "new"
              then "with the counterpart already using it"
              else "with both ends moving to a third key"
            }"):
                deploy(alpha, "${target}")
                ${lib.optionalString (target == "next") ''deploy(beta, "next", "other-psk")''}
                wait_state(alpha, "${target}")
                wait_state(beta, "${target}")
                for name, machine in members.items():
                    machine.wait_until_succeeds(request(instances[name]["peer"]), timeout=30)
                wait_clean()
          '';
      });
    rotationTest = name: scenario:
      pkgs.testers.runNixOSTest ({meshFixture, ...}: {
        imports = [(fixture {})];
        inherit name;
        testScript =
          meshFixture.script
          + helpers meshFixture
          + ''
            setup_mesh()
            application_pids = {}
            for name, machine in members.items():
                wait_state(machine, "old")
                machine.wait_until_succeeds(request(instances[name]["peer"]), timeout=60)
                application_pids[name] = machine.succeed("systemctl show app.service --property=MainPID --value").strip()
                machine.succeed(
                    "systemd-run --unit=mesh-test-traffic ${traffic} " + request(instances[name]["peer"])
                )
          ''
          + scenario
          + ''
            with subtest("application traffic and processes remain uninterrupted throughout rotation"):
                for name, machine in members.items():
                    machine.succeed("systemctl is-active mesh-test-traffic.service")
                    assert machine.succeed(request(instances[name]["peer"])).strip() == instances[name]["peer"]
                    assert machine.succeed("systemctl show app.service --property=MainPID --value").strip() == application_pids[name]
                    machine.succeed("systemctl stop mesh-test-traffic.service")
          '';
      });
  in {
    checks = {
      mesh-psk-one-sided = rotationTest "mesh-psk-one-sided" ''
        with subtest("a one-sided deployment keeps the old key through a session refresh"):
            handshake = latest_handshake(alpha)
            deploy(alpha, "new")
            wait_advert("alpha", "new", ["old"])
            wait_handshake(alpha, handshake)
            wait_state(alpha, "old", "new")
            wait_state(beta, "old")

        with subtest("rollback before agreement keeps the old key"):
            deploy(alpha, "old")
            wait_state(alpha, "old")
            wait_clean()

        with subtest("both ends rotate, and a later rollback keeps the agreed key"):
            deploy(alpha, "new")
            deploy(beta, "new")
            wait_state(alpha, "new")
            wait_state(beta, "new")
            wait_clean()
            deploy(beta, "old")
            wait_advert("beta", "old", ["new"])
            wait_state(beta, "new", "old")
            wait_state(alpha, "new")
            deploy(beta, "new")
            wait_clean()
      '';
      mesh-psk-withdrawal = rotationTest "mesh-psk-withdrawal" ''
        with subtest("an end cut off from etcd never switches alone"):
            deploy(alpha, "new")
            wait_advert("alpha", "new", ["old"])
            cut_from_etcd(alpha)
            deploy(beta, "new")
            wait_state(beta, "old", "new")
            deploy(beta, "old")
            wait_state(beta, "old")
            wait_state(alpha, "old", "new")

        with subtest("both ends switch once the cut-off end is back and both want the key"):
            restore_etcd(alpha)
            deploy(beta, "new")
            wait_state(alpha, "new")
            wait_state(beta, "new")
            wait_clean()
      '';
      mesh-psk-offline-rekey = rotationTest "mesh-psk-offline-rekey" ''
        with subtest("the installed keys establish a new session while one end is cut off"):
            deploy(alpha, "new")
            wait_advert("alpha", "new", ["old"])
            cut_from_etcd(alpha)
            handshake = latest_handshake(alpha)
            wait_handshake(alpha, handshake)
            wait_state(alpha, "old", "new")
            wait_state(beta, "old")
            for name, machine in members.items():
                peer = instances[name]["peer"]
                assert machine.succeed(request(peer)).strip() == peer
            restore_etcd(alpha)
            deploy(beta, "new")
            wait_state(alpha, "new")
            wait_state(beta, "new")
            wait_clean()
      '';
      mesh-psk-rotation = rotationTest "mesh-psk-rotation" ''
        with subtest("deploying the same key on both ends rotates on the next handshake"):
            deploy(alpha, "new")
            deploy(beta, "new")
            wait_state(alpha, "new")
            wait_state(beta, "new")
            wait_handshake(alpha, latest_handshake(alpha))
            wait_clean()

        with subtest("a delayed end catches up with the agreed key, even after its own rollback"):
            deploy(beta, "next")
            wait_advert("beta", "next", ["new"])
            wait_state(beta, "new", "next")
            # A stopped netd applies nothing until it continues. Freezing its unit
            # would also freeze the other container's netd, so stop the process.
            netd_pid = "$(systemctl show idr-mesh-netd.service --property=MainPID --value)"
            beta.succeed("systemctl start idr-mesh-netd.service", f"kill -STOP {netd_pid}")
            deploy(alpha, "next")
            wait_state(alpha, "next")
            assert kernel_hash(beta) == hashes["new"]
            wait_advert("alpha", "next")
            # Roll back while netd is stopped; once it continues it applies the latest state.
            beta.succeed(
                f"install -m 0400 {key_files['new']} /run/mesh-test-secrets/psk",
                "systemctl restart mesh-test-secrets.target",
            )
            assert kernel_hash(beta) == hashes["new"]
            beta.succeed(f"kill -CONT {netd_pid}")
            wait_state(beta, "next", "new")
            deploy(beta, "next")
            wait_state(beta, "next")
            wait_clean()
      '';
      mesh-psk-recovery = recoveryTest {
        name = "mesh-psk-recovery";
        target = "next";
      };
      mesh-psk-peer-ready = recoveryTest {
        name = "mesh-psk-peer-ready";
        target = "new";
      };
    };
  };
}

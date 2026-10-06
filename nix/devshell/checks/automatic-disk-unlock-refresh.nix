top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    checks = {
      automatic-disk-unlock-refresh = let
        fixture = config.checks.automatic-disk-unlock;
        currentNodes = fixture.config.nodes.server.idr.disk-unlock.server.nodes;
        staleNodes = map (node:
          if node.profiles.system.path.idr.meta.machine != "client"
          then node
          else
            lib.recursiveUpdate node {
              profiles.system.path.idr.meta = {
                initrdHostPublicKey = lib.fileContents ./fixtures/disk-unlock/stale-client-initrd-key.pub;
                disko.preFormatFiles."/disk-key.txt".sopsFile = ./fixtures/disk-unlock/stale-disk-key.enc.json;
              };
            })
        currentNodes;
      in
        fixture.extend {
          modules = [
            {
              name = lib.mkForce "automatic-disk-unlock-refresh";
              nodes.server = {
                idr.disk-unlock.server.nodes = lib.mkOverride 60 staleNodes;
                specialisation.refreshed.configuration.idr.disk-unlock.server.nodes = lib.mkForce currentNodes;
              };
              testScript = lib.mkForce ''
                start_all()
                server.wait_for_unit("idr-disk-unlock.socket")
                server.wait_for_unit("sops-install-secrets.service")
                client.wait_for_unit("prepare-encrypted-root.service")

                with subtest("an unlock server with the previous target identity cannot unlock the rotated target"):
                    client.shutdown()
                    client.start()
                    client.wait_for_console_text("Please enter passphrase for disk cryptroot")
                    server.wait_until_succeeds(
                        "journalctl -u 'idr-disk-unlock@*' --no-pager | grep -F 'Host key verification failed'"
                    )
                    server.fail("nc -z -w 2 client 22")

                with subtest("deploy refreshed target metadata and let the initrd retry automatically"):
                    server.succeed(
                        "/run/current-system/specialisation/refreshed/bin/switch-to-configuration test",
                        timeout=180,
                    )
                    client.wait_for_unit("multi-user.target")
                    assert client.succeed("findmnt -n -o SOURCE /").strip() == "/dev/mapper/cryptroot"
                    assert client.succeed("cat /unlock-test-marker").strip() == "persisted on the encrypted root"
                    server.wait_until_succeeds(
                        "journalctl -u 'idr-disk-unlock@*' --no-pager | grep -F 'Sent disk key to client-123456abcdef.'"
                    )
              '';
            }
          ];
        };
    };
  };
}

top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.preset-container-restart = pkgs.testers.runNixOSTest {
      imports = [
        (lib.modules.importApply ./preset-container-fixture.nix {inherit top;})
      ];

      name = "preset-container-restart";

      nodes.machine = {pkgs, ...}: {
        idr.preset.base.reloadContainersWhenPossible = false;
        containers.example.config.services.nginx = {
          enable = true;
          virtualHosts.localhost = {
            listen = [
              {
                addr = "127.0.0.1";
                port = 8080;
              }
            ];
            root = pkgs.writeTextDir "index.html" "initial container page";
          };
        };
        specialisation.updated.configuration.containers.example.config.services.nginx.virtualHosts.localhost.root =
          lib.mkForce (pkgs.writeTextDir "index.html" "updated container page");
      };

      testScript = ''
        start_all()
        machine.wait_for_unit("container@example.service")
        machine.wait_until_succeeds("curl --fail --silent http://127.0.0.1:8080/")
        assert machine.succeed("curl --fail --silent http://127.0.0.1:8080/") == "initial container page"
        leader = machine.succeed("machinectl show example -p Leader --value").strip()
        assert leader not in ["", "0"]

        with subtest("use the upstream container restart behavior when reloading is disabled"):
            machine.succeed(
                "/run/current-system/specialisation/updated/bin/switch-to-configuration test",
                timeout=300,
            )
            machine.wait_until_succeeds(
                "test \"$(curl --fail --silent http://127.0.0.1:8080/)\" = 'updated container page'"
            )
            updated_leader = machine.succeed("machinectl show example -p Leader --value").strip()
            assert updated_leader not in ["", "0", leader]
      '';
    };
  };
}

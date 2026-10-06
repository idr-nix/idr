top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    redisModule = pkgs.writeText "redis-flake-module.nix" ''
      _: {
        perSystem = _: {
          process-compose.idr.services.redis.cache = {
            enable = true;
            port = 6380;
            dataDir = ".data/redis";
          };
        };
      }
    '';
  in {
    checks.development-redis = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
    in {
      imports = with top.self.modules.nixosTest; [nix nix-store operator];

      name = "development-redis";
      globalTimeout = 20 * 60;

      idr.test.storePaths = [top.self.packages.${system}.default config.node.pkgs.redis];

      defaults = {pkgs, ...}: {
        systemd.services.idr-project-fixture = {
          description = "Restore the project archive with the documented Redis service";
          wantedBy = ["multi-user.target"];
          after = ["systemd-tmpfiles-setup.service"];
          path = [pkgs.coreutils pkgs.gnutar pkgs.gitMinimal];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "operator";
            Group = "operator";
            WorkingDirectory = "/home/operator";
          };
          script = ''
            tar -xf ${project}/project.tar
            mkdir -p project/nix/redis
            git -C project init -q
            git -C project add -A
            cp --no-preserve=mode ${redisModule} project/nix/redis/flake-module.nix
          '';
        };
      };

      containers = lib.optionalAttrs isLinux {machine = {};};
      nodes = lib.optionalAttrs (!isLinux) {
        machine = {
          virtualisation = {
            memorySize = 8192;
            cores = 8;
          };
          networking.useDHCP = false;
        };
      };

      testScript = ''
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        def redis(command):
            return operator("nix develop -c redis-cli -h 127.0.0.1 -p 6380 --raw " + command).strip()

        start_all()
        machine.wait_for_unit("idr-project-fixture.service")

        daemon_started = False
        try:
            with subtest("start the documented Redis service on port 6380"):
                operator("git add nix/redis/flake-module.nix")
                operator("nix develop -c idr -D")
                daemon_started = True
                machine.wait_for_open_port(6380, addr="127.0.0.1", timeout=120)
                assert redis("PING") == "PONG"

            with subtest("persist data in the documented project directory"):
                assert redis("SET documentation-example saved-value") == "OK"
                assert redis("SAVE") == "OK"
                operator("test -s .data/redis/dump.rdb")

            with subtest("recover saved data after restarting Redis"):
                operator("nix develop -c idr process restart cache")
                machine.wait_for_open_port(6380, addr="127.0.0.1", timeout=120)
                assert redis("PING") == "PONG"
                assert redis("GET documentation-example") == "saved-value"
        finally:
            if daemon_started:
                with subtest("stop the project and Redis"):
                    operator("nix develop -c idr down")
                    machine.wait_for_closed_port(6380, addr="127.0.0.1", timeout=60)
      '';
    });
  };
}

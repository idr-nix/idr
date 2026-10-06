top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    snapshot = pkgs.writeText "rotation-interval-observations.py" ''
      import hashlib
      import json
      import subprocess

      result = {}
      for filename, fields in {
          "secrets.enc.json": ["ssh_host_ed25519_key", "initrd_ssh_host_ed25519_key", "root_password"],
          "disk-key.enc.json": ["disk_key"],
      }.items():
          path = "nix/machine/test-machine/" + filename
          secrets = json.loads(subprocess.check_output(["sops", "decrypt", path]))
          for field in fields:
              annotation = dict(part.split("=", 1) for part in secrets[field + "@_unencrypted"].split())
              result[field] = {
                  "hash": hashlib.sha256(secrets[field].encode()).hexdigest(),
                  **annotation,
              }
      print(json.dumps(result))
    '';
  in {
    checks.rotate-keys-intervals = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
      machineId = top.self.nixosConfigurations."example-${system}".config.idr.preset.base.id;
    in {
      imports =
        (with top.self.modules.nixosTest; [nix nix-store operator ssh-git])
        ++ [
          (lib.modules.importApply ./fixtures/operator-project.nix {inherit project machineId;})
        ];

      name = "rotate-keys-intervals";
      globalTimeout = 25 * 60;
      idr.test.storePaths = [top.self.packages.${system}.default];
      defaults = {pkgs, ...}: {
        environment.systemPackages = [pkgs.python3];
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
        import json
        import shlex

        def operator(command):
            return machine.succeed(
                "su - operator -c " + shlex.quote("cd project && " + command),
                timeout=900,
            )

        start_all()
        machine.wait_for_unit("sshd.service")
        operator("nix flake update team")

        with subtest("edit an interval through SOPS and rotate only the expired field"):
            # Keep edits and observations in one shell: entering another shell also updates metadata.
            operator(
                "nix develop -c bash -euo pipefail <<'COMMANDS'\n"
                # The archived example's timestamps can already be older than its default interval.
                # Removing one annotation also checks the unconfigured default for a newly written one.
                "sops unset nix/machine/test-machine/secrets.enc.json '[\"initrd_ssh_host_ed25519_key@_unencrypted\"]'\n"
                "idr-rotate-keys --force test-machine\n"
                "python ${snapshot} > /tmp/interval-before.json\n"
                "disk=nix/machine/test-machine/disk-key.enc.json\n"
                "secrets=nix/machine/test-machine/secrets.enc.json\n"
                "annotation=$(jq -r '.\"disk_key@_unencrypted\"' \"$disk\")\n"
                "timestamp=''${annotation##*modified_ts=}\n"
                "sops set \"$disk\" '[\"disk_key@_unencrypted\"]' "
                "\"\\\"interval=0sec modified_ts=$timestamp\\\"\"\n"
                "idr-rotate-keys test-machine\n"
                "python ${snapshot} > /tmp/interval-expired.json\n"
                "annotation=$(jq -r '.\"disk_key@_unencrypted\"' \"$disk\")\n"
                "timestamp=''${annotation##*modified_ts=}\n"
                "sops set \"$disk\" '[\"disk_key@_unencrypted\"]' "
                "\"\\\"interval=180day modified_ts=$timestamp\\\"\"\n"
                "sha256sum \"$disk\" \"$secrets\" > /tmp/not-expired.sha256\n"
                "idr-rotate-keys test-machine\n"
                "sha256sum --check /tmp/not-expired.sha256\n"
                "sops unset \"$secrets\" '[\"root_password@_unencrypted\"]'\n"
                "env IDR_ROTATION_DEFAULT_INTERVAL=30day idr-rotate-keys --force test-machine\n"
                "python ${snapshot} > /tmp/interval-default.json\n"
                "COMMANDS"
            )

        with subtest("existing intervals persist and the override applies to new annotations"):
            before = json.loads(operator("cat /tmp/interval-before.json"))
            expired = json.loads(operator("cat /tmp/interval-expired.json"))
            default = json.loads(operator("cat /tmp/interval-default.json"))
            assert all(value["interval"] == "90day" for value in before.values()), before
            for field in before:
                if field == "disk_key":
                    assert expired[field]["hash"] != before[field]["hash"]
                    assert expired[field]["interval"] == "0sec"
                    assert int(expired[field]["modified_ts"]) >= int(before[field]["modified_ts"])
                else:
                    assert expired[field] == before[field], field
                assert default[field]["hash"] != expired[field]["hash"], field
            assert default["root_password"]["interval"] == "30day"
            assert default["disk_key"]["interval"] == "180day"
            assert default["ssh_host_ed25519_key"]["interval"] == "90day"
            assert default["initrd_ssh_host_ed25519_key"]["interval"] == "90day"
      '';
    });
  };
}

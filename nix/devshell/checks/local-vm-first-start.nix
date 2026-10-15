top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
    networkPrefix = "fd42:1234:5678";
  in {
    checks.local-vm-first-start = pkgs.testers.runNixOSTest ({config, ...}: let
      inherit (config.node.pkgs.stdenv.hostPlatform) system;
      inherit (pkgs.stdenv.hostPlatform) isDarwin;
      readinessTimeout =
        if isDarwin
        then 3600
        else 1800;
      pollInterval =
        if isDarwin
        then "5"
        else "1";
    in {
      imports = [
        (lib.modules.importApply ./local-vm-fixture.nix {
          inherit top project system;
          cachedImages = false;
        })
      ];

      idr.test.direnv.offline = true;
      name = "local-vm-first-start";
      globalTimeout = lib.mkForce ((
          if isDarwin
          then 90
          else 45
        )
        * 60);

      defaults = {pkgs, ...}: {
        idr.qemu.networkPrefix = lib.mkForce networkPrefix;
        # Inspection tools are separate from the project's ordinary runner.
        environment.systemPackages = [pkgs.qemu];
        systemd.services.idr-test-vm-logs = {
          description = "Forward the cold image build and first boot output";
          wantedBy = ["multi-user.target"];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/tail -n +1 -F /tmp/first-start-vm.log";
        };
      };

      testScript = ''
        import ipaddress
        import json
        import shlex

        start_all()
        machine.wait_for_unit("idr-project-fixture.service", timeout=600)
        machine.wait_for_unit("systemd-networkd.service")
        machine.succeed("test -x /run/wrappers/bin/qemu-bridge-helper && test ! -u /run/wrappers/bin/qemu-bridge-helper")
        assert "cap_net_admin" in machine.succeed("${pkgs.libcap.out}/bin/getcap /run/wrappers/bin/qemu-bridge-helper")
        machine.wait_until_succeeds(
            "ip -6 address show dev idr0 to ${networkPrefix}::1/128 | grep -q inet6"
        )
        machine.wait_until_succeeds(
            "ip -6 route show dev idr0 exact ${networkPrefix}::/48 | grep -q ."
        )

        shell = "cd /root/project && direnv exec . "
        log_file = "/tmp/first-start-vm.log"
        machine.succeed("touch " + log_file)
        machine_id = machine.succeed("cat /etc/machine-id").strip()
        image_dir = f"/root/project/.data/{machine_id}/test-machine/qemu"

        def assert_cold_cache():
            assert not machine.succeed(
                "find /root/project/.data "
                "\\( -name '*.qcow2' -o -name '*.raw' -o -name '*.partial' -o -name '*-pending' \\) -print"
            ).strip(), "the ordinary runner must begin without images or interrupted builds"
            machine.succeed("test ! -e " + shlex.quote(image_dir))

        daemon_started = False
        log_started = False
        failed = False
        try:
            with subtest("configure the real example before the first shell entry"):
                assert_cold_cache()
                configuration = "nix/machine/test-machine/configuration.nix"
                edit = '/networking.hostName =/a\\      idr.qemu.networkPrefix = "${networkPrefix}";'
                machine.succeed(
                    "cd /root/project && sed -i " + shlex.quote(edit) + " " + configuration
                    + " && git add " + configuration
                )
                machine.succeed("cd /root/project && direnv allow")
                # Retain both full-size NVMe disks, encrypted ZFS members and their mirror.
                disks = json.loads(machine.succeed(
                    "cd /root/project && nix --offline eval --json "
                    ".#nixosConfigurations.test-machine.config.disko.devices "
                    "--apply " + shlex.quote(
                        "devices: map (disk: { name = disk.imageName; size = disk.imageSize; }) "
                        "(builtins.attrValues devices.disk)"
                    ), timeout=600,
                ))

            with subtest("the ordinary runner builds its empty cache and boots once"):
                daemon_started = True
                machine.succeed(shell + "env IDR_QEMU_BUILD_MEMORY=8192 idr -D", timeout=600)
                assert_cold_cache()
                machine.succeed(shell + "idr process start vm-test-machine", timeout=120)
                log_started = True
                machine.succeed(shell + "bash -ec " + shlex.quote(
                    "nohup idr process logs --tail 100000 -f vm-test-machine > " + log_file
                    + " 2>&1 </dev/null & echo $! > " + log_file + ".pid"
                ), timeout=120)
                readiness = (
                    "idr process get vm-test-machine -o json | "
                    "jq -e 'length == 1 and .[0].is_running and .[0].is_ready == \"Ready\"'"
                )
                # One live devshell keeps repeated readiness polls cheap under TCG.
                machine.succeed(
                    shell + "bash -o pipefail -c " + shlex.quote(
                        "until " + readiness + "; do sleep ${pollInterval}; done"
                    ), timeout=${toString readinessTimeout},
                )
                assert machine.succeed(shell + "ssh vm-test-machine hostname", timeout=120).strip() == "test-machine"

            with subtest("the first installed boot uses the custom IPv6 alias and address"):
                ssh_config = machine.succeed(shell + "ssh -G vm-test-machine", timeout=120)
                settings = dict(line.split(" ", 1) for line in ssh_config.splitlines())
                address = ipaddress.IPv6Address(settings["hostname"])
                assert address in ipaddress.IPv6Network("${networkPrefix}::/48"), address
                interfaces = json.loads(machine.succeed(
                    shell + "ssh vm-test-machine " + shlex.quote("ip -j -6 address show"), timeout=120,
                ))
                assert any(ipaddress.IPv6Address(info["local"]) == address
                           for interface in interfaces for info in interface["addr_info"]), interfaces
                machine.succeed(shell + "ssh vm-test-machine ping -6 -c 1 -W 5 ${networkPrefix}::1", timeout=120)
                machine.wait_until_succeeds(
                    "grep -Fq 'idr-mk-images: using generated raw images' " + log_file,
                    timeout=30,
                )
                vm_log = machine.succeed("cat " + log_file)
                assert vm_log.count("idr-mk-images: using generated raw images") == 1, vm_log
                assert "idr-mk-images: reusing" not in vm_log, vm_log
        except Exception:
            failed = True
            if daemon_started:
                print(machine.execute(shell + "idr process logs --tail 1000 vm-test-machine", timeout=120))
            raise
        finally:
            try:
                if daemon_started:
                    status, output = machine.execute(
                        "timeout --kill-after=5s 110s bash -c " + shlex.quote(shell + "idr down"),
                        timeout=120,
                    )
                    if failed:
                        print((status, output))
                    else:
                        assert status == 0, output
                        machine.wait_until_succeeds(
                            shell + "bash -c " + shlex.quote(
                                "idr process get vm-test-machine -o json; status=$?; "
                                'test "$status" -gt 0 && test "$status" -lt 124'
                            ), timeout=60,
                        )
                        machine.wait_until_succeeds(
                            "if pgrep qemu-system-; then exit 1; else test $? -eq 1; fi",
                            timeout=60,
                        )
            finally:
                if log_started:
                    machine.execute("kill $(cat " + log_file + ".pid)")
                    machine.wait_until_succeeds(
                        "if pgrep -f '[i]dr process logs --tail 100000 -f vm-test-machine'; "
                        "then exit 1; else test $? -eq 1; fi", timeout=30,
                    )
                machine.copy_from_machine(log_file)

        with subtest("the first start created every standalone configured disk image"):
            images = machine.succeed(
                "find " + shlex.quote(image_dir) + " -maxdepth 1 -type f -name '*.qcow2' -printf '%f\\n'"
            ).splitlines()
            assert sorted(images) == sorted(f"{disk['name']}.qcow2" for disk in disks), images
            for disk in disks:
                image = shlex.quote(f"{image_dir}/{disk['name']}.qcow2")
                info = json.loads(machine.succeed("qemu-img info --output=json " + image))
                assert info["format"] == "qcow2", info
                assert info["virtual-size"] == int(disk["size"]), info
                assert not info.get("backing-filename"), info
            unfinished = machine.succeed(
                "find /root/project/.data "
                "\\( -name '*.raw' -o -name '*.partial' -o -name '*-pending' \\) -print"
            ).strip()
            assert not unfinished, unfinished
      '';
    });
  };
}

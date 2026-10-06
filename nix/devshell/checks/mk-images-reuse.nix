top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    archive = config.checks.mk-images;
    mkCheck = name: mode:
      pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        projectDirectory =
          if pkgs.stdenv.hostPlatform.isDarwin
          then "/run/idr-project-archive"
          else toString archive;
        # Plain harness code is copied to /tmp without adding a store registration root.
        scenario = (
          ''
            import json
            import shlex
            import subprocess
            import time
            from contextlib import contextmanager

            def execute(command, timeout=600):
                result = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", command],
                    stdout=subprocess.PIPE,
                    text=True,
                    timeout=timeout,
                )
                return result.returncode, result.stdout

            def project(command, timeout=600):
                status, output = execute(command, timeout)
                assert status == 0, (command, status, output)
                return output

            @contextmanager
            def subtest(name):
                started = time.monotonic()
                print(f"starting subtest: {name}", flush=True)
                yield
                print(f"subtest succeeded: {name} ({time.monotonic() - started:.2f}s)", flush=True)

            command = "idr-mk-images test-machine"
            receipt = ".idr-mk-images-test-machine-qcow2.json"
            disks = json.loads(project(
                "nix --offline eval --json .#nixosConfigurations.test-machine.config.disko.devices.disk "
                '--apply "disks: map (disk: { name = disk.imageName; size = disk.imageSize; }) '
                '(builtins.attrValues disks)"'
            ))

            def snapshot(directory, image_format):
                # Both file contents and inode identity must survive source reuse.
                images = f"{directory}/*.{image_format} " if image_format != "raw" else ""
                return project(
                    f"/run/current-system/sw/bin/sha256sum {images}{directory}/.idr-mk-images-*.json && "
                    f"stat -c '%n %i %s %y %z' {directory}/*.{image_format}"
                )

            def inspect(directory, image_format):
                for disk in disks:
                    image = shlex.quote(f"/home/operator/project/{directory}/{disk['name']}.{image_format}")
                    info = json.loads(project(f"qemu-img info --output=json {image}"))
                    assert info["format"] == image_format, info
                    assert info["virtual-size"] == int(disk["size"]), info
                    assert not info.get("backing-filename"), info
                    if image_format != "raw":
                        project(f"qemu-img check {image}")
                stored = json.loads(project(f"cat {directory}/.idr-mk-images-test-machine-{image_format}.json"))
                assert stored["format"] == image_format, stored
                assert stored["identity"]["builder"].endswith(".drv"), stored
                return stored

          ''
          + lib.optionalString (mode == "reuse") ''
            with subtest("reuse a configured source and preserve its images and receipt"):
                original = snapshot(".data/images", "qcow2")
                project("mkdir .data/export && rm .data/images/.idr-qemu.lock")
                log = project(command + " .data/export --source .data/images --type raw 2>&1")
                project("test -f .data/images/.idr-qemu.lock")
                assert "reusing qcow2 images" in log, log
                inspect(".data/export", "raw")
                assert snapshot(".data/images", "qcow2") == original

            with subtest("reuse RAW in the same directory without deleting it"):
                raw = snapshot(".data/export", "raw")
                log = project(command + " .data/export --source .data/export 2>&1")
                assert "reusing raw images" in log, log
                inspect(".data/export", "qcow2")
                # Adding another receipt changes the snapshot list, so check the RAW
                # image and its own receipt explicitly for this conversion.
                after = snapshot(".data/export", "raw")
                for line in raw.splitlines():
                    assert line in after.splitlines(), (line, after)

            with subtest("same-directory same-format reuse does not replace disk files"):
                before = snapshot(".data/export", "qcow2")
                log = project(command + " .data/export --source .data/export 2>&1")
                assert "reusing qcow2 images" in log, log
                assert snapshot(".data/export", "qcow2") == before

            with subtest("a read-only archive without a lock remains a usable source"):
                project("mkdir .data/readonly-export && rm .data/images/.idr-qemu.lock && chmod a-w .data/images")
                try:
                    log = project(command + " .data/readonly-export --source .data/images 2>&1")
                    assert "reusing qcow2 images" in log, log
                    inspect(".data/readonly-export", "qcow2")
                    project("test ! -e .data/images/.idr-qemu.lock")
                    assert snapshot(".data/images", "qcow2") == original
                finally:
                    project("chmod u+w .data/images")

            with subtest("an active VM lock prevents exporting its source"):
                project("touch .data/images/.idr-qemu.lock")
                locked_command = (
                    "flock .data/images/.idr-qemu.lock "
                    "sh -c " + shlex.quote(command + " .data/export --source .data/images")
                )
                status, output = execute(locked_command + " 2>&1")
                assert status == 75, (status, output)
                assert "images are in use" in output, output
                assert snapshot(".data/images", "qcow2") == original

          ''
          + lib.optionalString (mode == "refresh") ''
            with subtest("a changed machine configuration rebuilds instead of reusing old images"):
                original = snapshot(".data/images", "qcow2")
                old = inspect(".data/images", "qcow2")
                project("mkdir .data/export")
                builder = project("nix --offline eval --raw '.#idrDiskoImagesScript.test-machine.drvPath'").strip()
                assert builder != old["identity"]["builder"], (builder, old)
                selected = shlex.quote(json.dumps([disk["name"] for disk in disks]))
                interrupted = (
                    "bash -c " + shlex.quote(
                        'PATH="$IDR_TEST_INTERRUPTED_CONVERSION:$PATH" '
                        'IDR_TEST_CONVERSION_COMPLETED="$PWD/.data/first-conversion-completed" '
                        "IDR_MK_IMAGES_INTERNAL_IMAGE_NAMES_JSON=" + selected + " " +
                        "idr-mk-images test-machine .data/export --source .data/images --build-memory 4096 --jobs 1"
                    )
                )
                status, output = execute(interrupted + " 2>&1", timeout=2700)
                assert status != 0, (status, output)
                assert "Second conversion deliberately interrupted" in output, output
                project("test ! -e .data/export/" + receipt)
                converted = project("find .data/export -maxdepth 1 -name '*.qcow2' -printf '%f\\n'").splitlines()
                assert converted == [disks[0]["name"] + ".qcow2"], converted
                first_image = project("/run/current-system/sw/bin/sha256sum .data/export/*.qcow2 && stat -c '%i %s %y %z' .data/export/*.qcow2")
                pending = ".data/export/.idr-mk-images-test-machine-pending"
                project("test -f " + pending + "/.idr-mk-images-test-machine-raw.json")

            with subtest("resume converts only missing disks and certifies the complete generation"):
                missing = shlex.quote(json.dumps([disk["name"] for disk in disks[1:]]))
                resumed = "env IDR_MK_IMAGES_INTERNAL_IMAGE_NAMES_JSON=" + missing + " " + command
                log = project(resumed + " .data/export --source .data/images --build-memory 4096 2>&1", timeout=600)
                assert "using generated raw images" in log, log
                assert "Decrypting" not in log, log
                for line in first_image.splitlines():
                    assert line in project("/run/current-system/sw/bin/sha256sum .data/export/*.qcow2 && stat -c '%i %s %y %z' .data/export/*.qcow2").splitlines(), line
                current = inspect(".data/export", "qcow2")
                assert current["identity"]["builder"] == builder, current
                assert snapshot(".data/images", "qcow2") == original
                unfinished = project("find .data/export -name '*.raw' -o -name '*.partial' -o -name '*-pending'").strip()
                assert not unfinished, unfinished
          ''
          + lib.optionalString (mode == "invalid") ''
            def reject_cache(source):
                attempted = (
                    "env IDR_IMAGE_BUILD_VM=$(command -v reject-image-build) " + command +
                    " .data/empty --source " + source + " --type raw --build-memory 4096"
                )
                status, output = execute(attempted + " 2>&1", timeout=600)
                assert status != 0, (status, output)
                assert "Image generation deliberately rejected" in output, output
                unfinished = project("find .data/empty -name '*.raw' -o -name '*.json' -o -name '*.partial'").strip()
                assert not unfinished, unfinished

            project("mkdir .data/empty .data/incomplete .data/raw")
            original = snapshot(".data/images", "qcow2")
            with subtest("unreceipted and incomplete sets cannot be reused"):
                project("cp --reflink=auto .data/images/*.qcow2 .data/incomplete/")
                reject_cache(".data/incomplete")
                project("cp .data/images/" + receipt + " .data/incomplete/")
                project("rm .data/incomplete/" + shlex.quote(disks[0]["name"] + ".qcow2"))
                reject_cache(".data/incomplete")

            with subtest("one-byte RAW truncation is rejected even when qemu rounds its reported size"):
                log = project(command + " .data/raw --source .data/images --type raw 2>&1")
                assert "reusing qcow2 images" in log, log
                inspect(".data/raw", "raw")
                damaged = ".data/raw/" + shlex.quote(disks[0]["name"] + ".raw")
                project("truncate -s -1 " + damaged)
                # The obsolete marker must not override file validation.
                project("printf '%s' " + shlex.quote(json.dumps([disk["name"] for disk in disks])) +
                        " > .data/raw/.idr-mk-images-test-machine-raw-complete")
                reject_cache(".data/raw")

            with subtest("encrypted installation input changes invalidate previously current images"):
                project("printf '\\n' >> nix/machine/test-machine/disk-key.enc.json && "
                        "git add nix/machine/test-machine/disk-key.enc.json")
                # The changed tracked input gets a fresh devshell entry.
                command = "nix --offline develop -c idr-mk-images test-machine"
                reject_cache(".data/images")
                assert snapshot(".data/images", "qcow2") == original
          ''
        );
      in {
        imports = [(lib.modules.importApply ./nested-qemu-fixture.nix {})] ++ (with top.self.modules.nixosTest; [nix nix-store operator]);
        inherit name;
        globalTimeout = 60 * 60;
        idr.test.storePaths = [top.self.packages.${system}.default];
        nodeDefaults.virtualisation = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
          sharedDirectories.project-archive = {
            source = toString archive;
            target = projectDirectory;
            securityModel = "none";
          };
          fileSystems.${projectDirectory}.options = ["ro"];
        };
        defaults = {pkgs, ...}: let
          interruptedConversion = pkgs.writeShellScriptBin "qemu-img" ''
            set -euo pipefail
            if [ "$1" = convert ] && [ "$2" = -f ] && [ "$3" = raw ] && [ "$4" = -O ] && [ "$5" = qcow2 ]; then
              if [ -e "$IDR_TEST_CONVERSION_COMPLETED" ]; then
                echo "Second conversion deliberately interrupted" >&2
                exit 97
              fi
              ${pkgs.qemu}/bin/qemu-img "$@"
              touch "$IDR_TEST_CONVERSION_COMPLETED"
            else
              exec ${pkgs.qemu}/bin/qemu-img "$@"
            fi
          '';
        in {
          environment.variables = lib.optionalAttrs (mode == "refresh") {
            IDR_TEST_INTERRUPTED_CONVERSION = "${interruptedConversion}/bin";
          };
          environment.systemPackages = [
            pkgs.qemu
            # Python executes the assertion harness; IDR is supplied by the devshell.
            pkgs.python3
            pkgs.util-linux
            pkgs.jq
            (pkgs.writeShellScriptBin "reject-image-build" ''
              echo "Image generation deliberately rejected by cache-miss test" >&2
              exit 97
            '')
          ];
          systemd.services.idr-project-fixture = {
            description = "Restore installed images for image reuse checks";
            wantedBy = ["multi-user.target"];
            after = ["systemd-tmpfiles-setup.service"];
            path = with pkgs; [gnutar gitMinimal];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "operator";
              Group = "operator";
              WorkingDirectory = "/home/operator";
            };
            script = ''
              tar -xf ${projectDirectory}/project.tar
              git -C project init -q
              git -C project add -A
            '';
          };
        };
        testScript = ''
          import shlex

          start_all()
          machine.wait_for_unit("idr-project-fixture.service", timeout=600)

          def project(command):
              return machine.succeed("su - operator -c " + shlex.quote("cd project && " + command), timeout=3500)

          ${lib.optionalString (mode == "refresh") ''
            # Enter the shell after changing the configuration; both interrupted
            # conversion and resume then use this same real shell generation.
            project("sed -i '/# misc/a\\    { environment.etc.\"image-reuse-generation\".text = \"updated\"; }' "
                    "nix/machine/test-machine/configuration.nix")
            project("git add nix/machine/test-machine/configuration.nix")
          ''}
          # Keep harness files outside the project and its Nix input snapshot.
          scenario = ${builtins.toJSON scenario}
          machine.succeed("printf %s " + shlex.quote(scenario) + " > /tmp/idr-image-scenario.py")
          # Keep assertions beside the commands inside one genuine devshell.
          print(project("nix --offline develop -c /run/current-system/sw/bin/python3 -u /tmp/idr-image-scenario.py"))
        '';
      });
  in {
    checks = {
      mk-images-reuse = mkCheck "mk-images-reuse" "reuse";
      mk-images-reuse-invalid = mkCheck "mk-images-reuse-invalid" "invalid";
      mk-images-refresh = mkCheck "mk-images-refresh" "refresh";
    };
  };
}

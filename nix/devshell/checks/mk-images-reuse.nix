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
      in {
        imports = [(lib.modules.importApply ./nested-qemu-fixture.nix {})] ++ (with top.self.modules.nixosTest; [base operator]);
        idr.test.direnv.offline = true;
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
            if [ "$#" -ge 7 ] && [ "$1" = convert ] && [ "$2" = -f ] && [ "$3" = raw ] && [ "$4" = -O ] && [ "$5" = qcow2 ]; then
              input=''${@: -2:1}
              if [ "$input" = "$IDR_TEST_INTERRUPTED_IMAGE" ]; then
                echo "Selected disk conversion deliberately interrupted" >&2
                exit 97
              fi
            fi
            exec ${pkgs.qemu}/bin/qemu-img "$@"
          '';
        in {
          environment.variables = lib.optionalAttrs (mode == "refresh") {
            IDR_TEST_INTERRUPTED_CONVERSION = "${interruptedConversion}/bin";
          };
          environment.systemPackages = [
            pkgs.qemu
            pkgs.util-linux
            pkgs.b3sum
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
        testScript =
          ''
            import json
            import os
            import shlex
            import time

            build_cores = int(os.environ.get("NIX_BUILD_CORES", "0"))
            hash_threads = min(4, build_cores or 4)
            checksum = f"/run/current-system/sw/bin/b3sum --num-threads {hash_threads}"

            start_all()
            machine.wait_for_unit("idr-project-fixture.service", timeout=600)

            def user_command(command, **kwargs):
                return machine.succeed(
                    "su - operator -c " + shlex.quote("cd project && " + command),
                    **kwargs,
                )

            user_command("direnv allow", timeout=600)
            ${lib.optionalString (mode == "refresh") ''
              # Load the changed configuration on the first command, without a warmup.
              user_command("sed -i '/# misc/a\\    { environment.etc.\"image-reuse-generation\".text = \"updated\"; }' "
                           "nix/machine/test-machine/configuration.nix && "
                           "git add nix/machine/test-machine/configuration.nix", timeout=3500)
            ''}
            # Retain the former complete-scenario deadline as well as each command's limit.
            scenario_deadline = time.monotonic() + 3500

            def loaded_command(command):
                return "su - operator -c " + shlex.quote(
                    "cd project && direnv exec . bash -euo pipefail -c " + shlex.quote(command)
                )

            def command_timeout(timeout):
                remaining = scenario_deadline - time.monotonic()
                assert remaining > 0, "image reuse scenario exceeded 3500 seconds"
                return min(timeout, remaining)

            def execute(command, timeout=600):
                return machine.execute(loaded_command(command), timeout=command_timeout(timeout))

            def project(command, timeout=600):
                return machine.succeed(loaded_command(command), timeout=command_timeout(timeout))

            def fixture(command, timeout=600):
                # Fixture setup and assertions use the tools installed in the test machine.
                return user_command(
                    "bash -euo pipefail -c " + shlex.quote(command),
                    timeout=command_timeout(timeout),
                )

            command = "idr-mk-images test-machine"
            receipt = ".idr-mk-images-test-machine-qcow2.json"
            ${
              if mode == "refresh"
              then ''
                image_info = json.loads(project("nix --offline eval --json .#idrDiskoImagesInfo.test-machine"))
                builder = image_info["builder"]
                disks = [
                    {"name": disk["imageName"], "size": disk["size"]}
                    for disk in image_info["metadata"]["disks"].values()
                ]
              ''
              else ''
                disks = json.loads(project(
                    "nix --offline eval --json .#nixosConfigurations.test-machine.config.disko.devices.disk "
                    '--apply "disks: map (disk: { name = disk.imageName; size = disk.imageSize; }) '
                    '(builtins.attrValues disks)"'
                ))
              ''
            }
            def snapshot(directory, image_format):
                # Both file contents and inode identity must survive source reuse.
                images = f"{directory}/*.{image_format} " if image_format != "raw" else ""
                return fixture(
                    f"{checksum} {images}{directory}/.idr-mk-images-*.json && "
                    f"stat -c '%n %i %s %y %z' {directory}/*.{image_format}"
                )

            def inspect(directory, image_format):
                for disk in disks:
                    image = shlex.quote(f"/home/operator/project/{directory}/{disk['name']}.{image_format}")
                    info = json.loads(fixture(f"qemu-img info --output=json {image}"))
                    assert info["format"] == image_format, info
                    assert info["virtual-size"] == int(disk["size"]), info
                    assert not info.get("backing-filename"), info
                    if image_format != "raw":
                        fixture(f"qemu-img check {image}")
                stored = json.loads(fixture(f"cat {directory}/.idr-mk-images-test-machine-{image_format}.json"))
                assert stored["format"] == image_format, stored
                assert stored["identity"]["builder"].endswith(".drv"), stored
                return stored

          ''
          + lib.optionalString (mode == "reuse") ''
            with subtest("reuse a configured source and preserve its images and receipt"):
                original = snapshot(".data/images", "qcow2")
                fixture("mkdir .data/export && rm .data/images/.idr-qemu.lock")
                log = project(command + " .data/export --source .data/images --type raw 2>&1")
                fixture("test -f .data/images/.idr-qemu.lock")
                assert "reusing qcow2 images" in log, log
                inspect(".data/export", "raw")
                assert snapshot(".data/images", "qcow2") == original

            with subtest("reuse RAW in the same directory without deleting it"):
                raw = snapshot(".data/export", "raw")
                log = project(command + " .data/export --source .data/export --jobs 1 2>&1")
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
                fixture("mkdir .data/readonly-export && rm .data/images/.idr-qemu.lock && chmod a-w .data/images")
                try:
                    log = project(command + " .data/readonly-export --source .data/images 2>&1")
                    assert "reusing qcow2 images" in log, log
                    inspect(".data/readonly-export", "qcow2")
                    fixture("test ! -e .data/images/.idr-qemu.lock")
                    assert snapshot(".data/images", "qcow2") == original
                finally:
                    fixture("chmod u+w .data/images")

            with subtest("an active VM lock prevents exporting its source"):
                fixture("touch .data/images/.idr-qemu.lock")
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
                fixture("mkdir .data/export")
                assert builder != old["identity"]["builder"], (builder, old)
                assert len(disks) >= 2, disks
                pending = ".data/export/.idr-mk-images-test-machine-pending"
                interrupted_image = pending + "/" + disks[1]["name"] + ".raw"
                selected = shlex.quote(json.dumps([disk["name"] for disk in disks]))
                # Inject PATH after direnv has loaded its cached environment.
                # Fail a specific disk, independently of which parallel worker finishes first.
                interrupted = (
                    'PATH="$IDR_TEST_INTERRUPTED_CONVERSION:$PATH" '
                    'IDR_TEST_INTERRUPTED_IMAGE="$PWD/"' + shlex.quote(interrupted_image) + " " +
                    "IDR_MK_IMAGES_INTERNAL_IMAGE_NAMES_JSON=" + selected + " " +
                    "idr-mk-images test-machine .data/export --source .data/images --build-memory 8192 --jobs 2"
                )
                status, output = execute(interrupted + " 2>&1", timeout=2700)
                (machine.out_dir / "image-refresh.log").write_text(output)
                assert status != 0, (status, output)
                assert "Selected disk conversion deliberately interrupted" in output, output
                fixture("test ! -e .data/export/" + receipt)
                converted = fixture("find .data/export -maxdepth 1 -name '*.qcow2' -printf '%f\\n'").splitlines()
                assert converted == [disks[0]["name"] + ".qcow2"], converted
                first_disk = shlex.quote(".data/export/" + disks[0]["name"] + ".qcow2")
                first_image_command = (
                    f"{checksum} {first_disk} && "
                    f"stat -c '%i %s %y %z' {first_disk}"
                )
                first_image = fixture(first_image_command)
                fixture("test -f " + pending + "/.idr-mk-images-test-machine-raw.json")

            with subtest("resume converts only missing disks and certifies the complete generation"):
                missing = shlex.quote(json.dumps([disk["name"] for disk in disks[1:]]))
                resumed = "env IDR_MK_IMAGES_INTERNAL_IMAGE_NAMES_JSON=" + missing + " " + command
                log = project(resumed + " .data/export --source .data/images --build-memory 8192 2>&1", timeout=600)
                assert "using generated raw images" in log, log
                assert "Decrypting" not in log, log
                resumed_image = fixture(first_image_command)
                assert resumed_image == first_image, (first_image, resumed_image)
                current = inspect(".data/export", "qcow2")
                assert current["identity"]["builder"] == builder, current
                assert snapshot(".data/images", "qcow2") == original
                unfinished = fixture("find .data/export -name '*.raw' -o -name '*.partial' -o -name '*-pending'").strip()
                assert not unfinished, unfinished
          ''
          + lib.optionalString (mode == "invalid") ''
            def reject_cache(source, *, force=False):
                attempted = (
                    "env IDR_IMAGE_BUILD_VM=$(command -v reject-image-build) " + command +
                    " .data/empty --source " + source + " --type raw --build-memory 4096"
                )
                if force:
                    attempted += " --force"
                status, output = execute(attempted + " 2>&1", timeout=600)
                assert status != 0, (status, output)
                assert "Image generation deliberately rejected" in output, output
                unfinished = fixture("find .data/empty -name '*.raw' -o -name '*.json' -o -name '*.partial'").strip()
                assert not unfinished, unfinished

            fixture("mkdir .data/empty .data/incomplete .data/raw")
            original = snapshot(".data/images", "qcow2")
            with subtest("unreceipted and incomplete sets cannot be reused"):
                fixture("cp --reflink=auto .data/images/*.qcow2 .data/incomplete/")
                reject_cache(".data/incomplete")
                fixture("cp .data/images/" + receipt + " .data/incomplete/")
                fixture("rm .data/incomplete/" + shlex.quote(disks[0]["name"] + ".qcow2"))
                reject_cache(".data/incomplete")

            with subtest("one-byte RAW truncation is rejected even when qemu rounds its reported size"):
                log = project(command + " .data/raw --source .data/images --type raw 2>&1")
                assert "reusing qcow2 images" in log, log
                inspect(".data/raw", "raw")
                damaged = ".data/raw/" + shlex.quote(disks[0]["name"] + ".raw")
                fixture("truncate -s -1 " + damaged)
                # The obsolete marker must not override file validation.
                fixture("printf '%s' " + shlex.quote(json.dumps([disk["name"] for disk in disks])) +
                        " > .data/raw/.idr-mk-images-test-machine-raw-complete")
                reject_cache(".data/raw")

            with subtest("force bypasses a valid current image cache"):
                # The earlier successful conversion proves this source is reusable.
                # Reaching the rejecting builder proves --force does not take that shortcut.
                reject_cache(".data/images", force=True)
                assert snapshot(".data/images", "qcow2") == original

            with subtest("encrypted installation input changes invalidate previously current images"):
                fixture("printf '\\n' >> nix/machine/test-machine/disk-key.enc.json && "
                        "git add nix/machine/test-machine/disk-key.enc.json")
                # The next direnv exec reloads the changed tracked Nix input.
                reject_cache(".data/images")
                assert snapshot(".data/images", "qcow2") == original
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

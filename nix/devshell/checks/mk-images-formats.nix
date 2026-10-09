top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-images;
    mkFormatCheck = name: scenario:
      pkgs.testers.runNixOSTest ({
        config,
        hostPkgs,
        ...
      }: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        projectDirectory =
          if hostPkgs.stdenv.hostPlatform.isDarwin
          then "/run/idr-project-archive"
          else toString project;
      in {
        imports = [(lib.modules.importApply ./nested-qemu-fixture.nix {})] ++ (with top.self.modules.nixosTest; [base operator]);
        idr.test.direnv.offline = true;
        inherit name;
        globalTimeout = 60 * 60;
        idr.test.storePaths = [top.self.packages.${system}.default];

        nodeDefaults.virtualisation = lib.mkIf hostPkgs.stdenv.hostPlatform.isDarwin {
          sharedDirectories.project-archive = {
            source = toString project;
            target = projectDirectory;
            securityModel = "none";
          };
          fileSystems.${projectDirectory}.options = ["ro"];
        };

        defaults = {pkgs, ...}: {
          environment.systemPackages = [pkgs.qemu pkgs.util-linux];
          # These checks convert existing images; a cache miss must fail rather
          # than silently running another Disko build.
          environment.variables.IDR_IMAGE_BUILD_VM = pkgs.writeShellScript "unexpected-image-generation" ''
            echo "format conversion unexpectedly regenerated its source images" >&2
            exit 1
          '';
          systemd.services.idr-project-fixture = {
            description = "Restore the documented project and cached source images";
            wantedBy = ["multi-user.target"];
            after = ["systemd-tmpfiles-setup.service"];
            path = with pkgs; [coreutils gnutar gitMinimal];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "operator";
              Group = "operator";
              WorkingDirectory = "/home/operator";
            };
            script = ''
              tar -xf ${projectDirectory}/project.tar
              image_cache="project/.data/$(cat /etc/machine-id)/test-machine"
              mkdir -p "$image_cache"
              mv project/.data/images "$image_cache/qemu"
              git -C project init -q
              git -C project add -A
            '';
          };
        };

        testScript = ''
          import json
          import shlex
          import time

          start_all()
          machine.wait_for_unit("idr-project-fixture.service")
          machine.succeed("su - operator -c " + shlex.quote("cd project && direnv allow"), timeout=600)
          # Retain the former complete-scenario deadline as well as each command's limit.
          scenario_deadline = time.monotonic() + 3500

          def project(command, timeout=600):
              remaining = int(scenario_deadline - time.monotonic())
              assert remaining > 0, "image format scenario exceeded 3500 seconds"
              loaded = "cd project && direnv exec . bash -euo pipefail -c " + shlex.quote(command)
              return machine.succeed(
                  "su - operator -c " + shlex.quote(loaded),
                  timeout=min(timeout, remaining),
              )

          disks = json.loads(project(
              "nix --offline eval --json .#nixosConfigurations.test-machine.config.disko.devices.disk "
              '--apply "disks: map (disk: { name = disk.imageName; size = disk.imageSize; }) '
              '(builtins.attrValues disks)"'
          ))
          assert disks, "the example must have disks"

          image_cache = (
              "/home/operator/project/.data/" + project("cat /etc/machine-id").strip()
              + "/test-machine/qemu"
          )

          def source_snapshot():
              files = project(
                  f"find {image_cache} -maxdepth 1 -type f -printf '%f\\n'"
              ).splitlines()
              assert all(f"{disk['name']}.qcow2" in files for disk in disks), files
              assert ".idr-mk-images-test-machine-qcow2.json" in files, files
              snapshot = {}
              for name in sorted(files):
                  image = shlex.quote(f"{image_cache}/{name}")
                  snapshot[name] = (
                      project(f"/run/current-system/sw/bin/sha256sum {image}").split()[0],
                      project(f"stat -c '%i %s %y %z' {image}").strip(),
                  )
              return snapshot

          builder = project("printenv IDR_IMAGE_BUILD_VM").strip()
          assert builder.endswith("-unexpected-image-generation"), builder
          original_sources = source_snapshot()

          def assert_sources_retained():
              assert source_snapshot() == original_sources, "cached source images changed during conversion"

          def inspect_images(directory, image_format):
              actual = project(
                  f"find {directory} -maxdepth 1 -type f -name '*.{image_format}' -printf '%f\\n'"
              ).splitlines()
              expected = sorted(f"{disk['name']}.{image_format}" for disk in disks)
              assert sorted(actual) == expected, (expected, actual)
              for disk in disks:
                  image = shlex.quote(f"{directory}/{disk['name']}.{image_format}")
                  info = json.loads(project(f"qemu-img info --output=json {image}"))
                  assert info["format"] == image_format, info
                  assert info["virtual-size"] == int(disk["size"]), info
                  assert not info.get("backing-filename"), info
                  if image_format == "raw":
                      partitions = json.loads(project(f"sfdisk --json {image}"))["partitiontable"]
                      assert partitions["label"] == "gpt", partitions
                      assert partitions["partitions"], partitions
                  else:
                      if image_format == "vmdk":
                          assert info["format-specific"]["data"]["create-type"] == "streamOptimized", info
                          extents = info["format-specific"]["data"]["extents"]
                          assert extents and all(extent.get("compressed") for extent in extents), info
                      project(f"qemu-img check {image}", timeout=300)
              stored = json.loads(project(f"cat {directory}/.idr-mk-images-test-machine-{image_format}.json"))
              assert stored["format"] == image_format, stored
              assert stored["identity"]["builder"].endswith(".drv"), stored
              unfinished = project(f"find {directory} -name '*.partial' -print").strip()
              assert not unfinished, unfinished

          ${scenario}
        '';
      });
  in {
    checks = {
      mk-images-qcow2 = mkFormatCheck "mk-images-qcow2" ''
        with subtest("export cached images as compressed QCOW2"):
            project("mkdir .data/images")
            project(
                "cd .data/images && idr-mk-images test-machine -c -o compression_type=zstd",
                timeout=1800,
            )
            inspect_images("/home/operator/project/.data/images", "qcow2")
            for disk in disks:
                image = shlex.quote(f".data/images/{disk['name']}.qcow2")
                info = json.loads(project(f"qemu-img info --output=json {image}"))
                assert info["format-specific"]["data"]["compression-type"] == "zstd", info
                extents = json.loads(project(f"qemu-img map --output=json {image}"))
                assert any(extent.get("compressed") for extent in extents), extents

        with subtest("reconvert current QCOW2 images with different options"):
            project(
                "idr-mk-images test-machine .data/images -o cluster_size=131072",
                timeout=1800,
            )
            inspect_images("/home/operator/project/.data/images", "qcow2")
            for disk in disks:
                image = shlex.quote(f".data/images/{disk['name']}.qcow2")
                info = json.loads(project(f"qemu-img info --output=json {image}"))
                assert info["cluster-size"] == 131072, info
                extents = json.loads(project(f"qemu-img map --output=json {image}"))
                assert not any(extent.get("compressed") for extent in extents), extents
            assert_sources_retained()
      '';
      mk-images-raw = mkFormatCheck "mk-images-raw" ''
        with subtest("convert cached images to raw in an explicit destination"):
            project("mkdir .data/images")
            project(
                "idr-mk-images test-machine .data/images "
                "--type raw --build-memory 4096",
                timeout=1800,
            )
            inspect_images("/home/operator/project/.data/images", "raw")
            assert_sources_retained()

        with subtest("repair damaged raw output while retaining cached source images"):
            # Damage the old headers so an unchanged file cannot satisfy validation.
            project("for image in .data/images/*.raw; do truncate -s 1 \"$image\"; done")
            log = project(
                "idr-mk-images test-machine .data/images "
                "--type raw --build-memory 4096 2>&1",
                timeout=1800,
            )
            assert "reusing qcow2 images" in log, log
            inspect_images("/home/operator/project/.data/images", "raw")
            assert_sources_retained()
      '';
      mk-images-vmdk = mkFormatCheck "mk-images-vmdk" ''
        with subtest("convert cached images to stream-optimized VMDK in the current directory"):
            project("idr-mk-images test-machine -t vmdk -m 4096", timeout=1800)
            inspect_images("/home/operator/project", "vmdk")
            assert not project("find . -maxdepth 1 -name '*.raw' -print").strip()
            assert_sources_retained()
      '';
    };
  };
}

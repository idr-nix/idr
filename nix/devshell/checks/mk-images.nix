top: {lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    project = config.checks.mk-project;
  in {
    checks = {
      mk-images = pkgs.testers.runNixOSTest ({config, ...}: let
        inherit (config.node.pkgs.stdenv.hostPlatform) system;
        inherit (pkgs.stdenv.hostPlatform) isDarwin;
        archiveDirectory =
          if isDarwin
          then "/tmp/test-output"
          else "/tmp/shared";
        archivePath = "${archiveDirectory}/project.tar";
      in {
        imports = [(lib.modules.importApply ./nested-qemu-fixture.nix {})] ++ (with top.self.modules.nixosTest; [base operator]);

        idr.test.direnv.offline = true;
        name = "mk-images";
        globalTimeout = 60 * 60;

        idr.test.storePaths = [top.self.packages.${system}.default];

        # Share the test output directly, avoiding two copies of the large archive.
        # Linux uses the driver's nspawn shared directory below.
        nodeDefaults.virtualisation.sharedDirectories.test-output = lib.mkIf isDarwin {
          source = ''"$out"'';
          target = "/tmp/test-output";
          securityModel = "none";
        };

        defaults = {pkgs, ...}: {
          environment.systemPackages = [pkgs.qemu];
          systemd.services.idr-project-fixture = {
            description = "Restore the mk-project archive for image creation";
            wantedBy = ["multi-user.target"];
            after = ["systemd-tmpfiles-setup.service"];
            path = [pkgs.gnutar pkgs.gitMinimal];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "operator";
              Group = "operator";
              WorkingDirectory = "/home/operator";
            };
            script = ''
              tar -xf ${project}/project.tar
              git -C project init -q
              git -C project add -A
            '';
          };
        };

        testScript = ''
          import json
          import shlex

          def project(command, **kwargs):
              return machine.succeed(
                  "su - operator -c " + shlex.quote("cd project && " + command),
                  **kwargs,
              )

          ${lib.optionalString (!isDarwin) ''
            # Nspawn binds this exact directory at /tmp/shared when it starts.
            machine.shared_dir = machine.out_dir
          ''}
          start_all()
          machine.wait_for_unit("idr-project-fixture.service")
          project("direnv allow")
          ${lib.optionalString isDarwin ''
            machine.wait_for_unit("swap.target")
            machine.succeed("swapon --show && swapon --noheadings --show=NAME | grep -Fx /var/lib/idr-test.swap")
          ''}
          # Confirm the writable share is the driver's actual output directory.
          machine.succeed("touch ${archiveDirectory}/.idr-write-check")
          assert (machine.out_dir / ".idr-write-check").is_file()
          machine.succeed("rm ${archiveDirectory}/.idr-write-check")

          with subtest("build images for the archived machine following the documentation"):
              # Keep progress visible while the driver buffers command stdout.
              project(
                  "mkdir .data/images && "
                  "direnv exec . idr-mk-images test-machine .data/images --build-memory 8192 --jobs 2 >&2",
                  timeout=2700,
              )

          with subtest("validate every configured disk as a standalone QCOW2 image"):
              disks = json.loads(project(
                  "nix --offline eval --json "
                  ".#nixosConfigurations.test-machine.config.disko.devices.disk "
                  '--apply "disks: map (disk: { name = disk.imageName; size = disk.imageSize; }) '
                  '(builtins.attrValues disks)"'
              ))
              assert disks, "test-machine must have disks"
              image_dir = "/home/operator/project/.data/images"
              actual = machine.succeed(
                  f"find {image_dir} -maxdepth 1 -type f -name '*.qcow2' -printf '%f\\n'"
              ).splitlines()
              expected = sorted(f"{disk['name']}.qcow2" for disk in disks)
              assert sorted(actual) == expected, (expected, actual)

              for disk in disks:
                  image = shlex.quote(f"{image_dir}/{disk['name']}.qcow2")
                  machine.succeed(f"qemu-img check {image}", timeout=300)
                  info = json.loads(machine.succeed(f"qemu-img info --output=json {image}"))
                  assert info["format"] == "qcow2", info
                  assert info["virtual-size"] == int(disk["size"]), info
                  assert not info.get("backing-filename"), info
                  assert info["actual-size"] < info["virtual-size"], info
                  extents = json.loads(machine.succeed(f"qemu-img map --output=json {image}"))
                  assert not any(extent.get("compressed") for extent in extents), extents

              unfinished = machine.succeed(
                  f"find {image_dir} -maxdepth 1 -type f "
                  "\\( -name '*.raw' -o -name '*.partial' \\) -print"
              ).strip()
              assert not unfinished, unfinished

          with subtest("export the project and images for the local VM fixture"):
              machine.succeed(
                  "find /home/operator/project/.data -mindepth 1 -maxdepth 1 "
                  "! -name machine-host-key ! -name images -exec rm -rf {} +"
              )
              machine.succeed("rm -f /home/operator/project/.data/images/result")
              # The consumer moves .data/images into its host-specific test-machine/qemu cache.
              # The encrypted images barely compress; a plain tar avoids spending
              # CPU on gzip both here and in every consumer.
              machine.succeed(
                  "tar -C /home/operator --exclude=project/.git --sparse --sort=name --mtime=@0 "
                  "--owner=1000 --group=1000 --numeric-owner -c project > ${archivePath}",
                  timeout=600,
              )
        '';
      });
    };
  };
}

{lib, ...}: {
  perSystem = {pkgs, ...}: let
    provision = pkgs.writeText "microvm-provision-test.nu" ''
      use ${../../scripts/idr-common.nu} [with-disko-files]
      source ${../../microvm/provision.nu}
    '';
    builder = pkgs.writeShellScript "microvm-test-image-builder" ''
      set -e
      echo build >> "$BUILDER_CALLED"
      for image in $BUILDER_IMAGES; do
        cp "$SOURCE_IMAGE" "$image.raw"
      done
    '';
    probe = pkgs.writeShellScriptBin "wipefs" ''
      set -e
      if [ "''${FAIL_PROBE:-0}" = 1 ]; then
        echo "injected probe failure" >&2
        exit 1
      fi
      ${pkgs.util-linux}/bin/wipefs "$@"
      if [ -n "''${SWAP_PATH:-}" ]; then
        if [ -e "$SWAP_PATH.probed" ]; then
          mv "$SWAP_PATH" "$SWAP_PATH.original"
          ln -s "$SWAP_VICTIM" "$SWAP_PATH"
        else
          touch "$SWAP_PATH.probed"
        fi
      fi
    '';
  in {
    checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      microvm-provisioning =
        pkgs.runCommand "microvm-provisioning" {
          nativeBuildInputs = with pkgs; [coreutils nushell python3 qemu-utils sops util-linux e2fsprogs];
        } ''
          python3 <<'PY'
          import fcntl, hashlib, json, os, pathlib, stat, subprocess

          work = pathlib.Path.cwd()
          state = work / "state"
          state.mkdir()
          marker = work / "builder-called"
          source = work / "source.raw"

          def run(*args, **kwargs):
              return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)

          def blank(name, size=16 * 1024 * 1024):
              disk = work / name
              with disk.open("wb") as output:
                  output.truncate(size)
              return disk

          def digest(disk):
              return hashlib.sha256(disk.read_bytes()).digest()

          def provision_disks(disks, error=None, **extra_env):
              manifest = work / "manifest.json"
              manifest.write_text(json.dumps({
                  "machine": "worker", "unitName": "idr-microvm-worker",
                  "disks": [{"name": name, "path": str(disk), "format": fmt, "sizeMiB": None,
                             "provisioning": "image", "imageName": name}
                            for name, disk, fmt in disks],
                  "metadata": {"preFormatFiles": {}, "postFormatFiles": {}},
                  "builder": "${builder}", "buildMemoryMiB": 64,
              }))
              env = dict(os.environ, STATE_DIRECTORY=str(state), SOURCE_IMAGE=str(source),
                         BUILDER_CALLED=str(marker), BUILDER_IMAGES=" ".join(name for name, _, _ in disks),
                         PATH="${probe}/bin:" + os.environ["PATH"], **extra_env)
              marker.unlink(missing_ok=True)
              descriptors = {}
              try:
                  for name, disk, _ in disks:
                      descriptor = os.open(disk, os.O_RDONLY)
                      descriptors[name] = descriptor
                      fcntl.flock(descriptor, fcntl.LOCK_EX)
                  env["IDR_MICROVM_DISK_FDS"] = json.dumps(descriptors)
                  result = subprocess.run([
                      "nu", "--no-config-file", "--no-std-lib", "--no-history", "${provision}", str(manifest),
                  ], env=env, text=True, capture_output=True, pass_fds=tuple(descriptors.values()))
              finally:
                  for descriptor in descriptors.values():
                      os.close(descriptor)
              if error is None:
                  assert result.returncode == 0, result.stdout + result.stderr
              else:
                  assert result.returncode != 0 and error in result.stderr, result.stdout + result.stderr
              assert not list(state.glob(".bootstrap-*")), "bootstrap files were not cleaned"

          def provision_disk(disk, fmt="raw", error=None, **env):
              provision_disks([("system", disk, fmt)], error, **env)

          def preserved(disk, fmt="raw", error=None, **env):
              before = digest(disk)
              provision_disk(disk, fmt, error, **env)
              assert digest(disk) == before, f"modified existing disk: {disk}"
              assert not marker.exists(), f"built an installer for existing disk: {disk}"

          # An existing partition table is sufficient: no bootloader or OS is required.
          blank(source.name)
          run("sfdisk", str(source), input="label: gpt\n,8M,L\n")
          preserved(source)
          four_k = blank("partitioned-4k.raw")
          run("sfdisk", "--sector-size", "4096", str(four_k), input="label: gpt\n,8M,L\n")
          preserved(four_k)
          filesystem = blank("filesystem.raw")
          run("mkfs.ext4", "-q", "-F", str(filesystem))
          preserved(filesystem)
          # QEMU detects whole-disk LUKS as a format, but it is still used RAW storage.
          encrypted = work / "whole-disk-luks.raw"
          run("qemu-img", "create", "-f", "luks", "--object", "secret,id=key,data=test-key",
              "-o", "key-secret=key,iter-time=1", str(encrypted), "16M")
          signatures = json.loads(run("wipefs", "--no-act", "--json", "--output", "TYPE,USAGE", str(encrypted)).stdout)
          assert any(signature["type"] == "crypto_LUKS" for signature in signatures["signatures"])
          preserved(encrypted)
          payload = blank("payload.raw")
          with payload.open("r+b") as output:
              output.write(b"non-partitioned disk data\n")
          qcow = work / "populated.qcow2"
          run("qemu-img", "convert", "-f", "raw", "-O", "qcow2", str(payload), str(qcow))
          preserved(qcow, "qcow2")
          preserved(qcow)  # A container supplied as RAW must not be initialized either.

          # Unsupported QCOW2 features must fail before the disk or related files change.
          backing = work / "backing.qcow2"
          run("qemu-img", "create", "-f", "qcow2", "-F", "raw", "-b", str(source), str(backing))
          source_hash = digest(source)
          preserved(backing, "qcow2", "Backing files are not supported")
          assert digest(source) == source_hash
          external = work / "external.qcow2"
          data = work / "external.data"
          run("qemu-img", "create", "-f", "qcow2", "-o", f"data_file={data},data_file_raw=on", str(external), "16M")
          data_hash = digest(data)
          preserved(external, "qcow2", "External data files")
          assert digest(data) == data_hash
          extended = work / "extended.qcow2"
          run("qemu-img", "create", "-f", "qcow2", "-o", "extended_l2=on", str(extended), "16M")
          preserved(extended, "qcow2", "extended L2 tables")

          disk = blank("blank.raw")
          disk.chmod(0o640)
          before = disk.stat()
          provision_disk(disk)
          after = disk.stat()
          assert marker.exists() and digest(disk) == source_hash
          assert (after.st_ino, stat.S_IMODE(after.st_mode), after.st_uid, after.st_gid) == (
              before.st_ino, 0o640, before.st_uid, before.st_gid)
          preserved(blank("probe-failure.raw"), error="injected probe failure", FAIL_PROBE="1")

          # A used disk is preserved while every blank disk shares one image build.
          first = blank("multi-first.raw")
          second = work / "multi-second.qcow2"
          run("qemu-img", "create", "-f", "qcow2", str(second), "16M")
          provision_disks([("system", source, "raw"), ("data", first, "raw"), ("archive", second, "qcow2")])
          assert marker.read_text().splitlines() == ["build"], "ran the builder more than once"
          assert digest(source) == source_hash and digest(first) == source_hash
          run("qemu-img", "compare", "-f", "raw", "-F", "qcow2", str(source), str(second))
          before_second = digest(second)
          provision_disks([("system", source, "raw"), ("data", first, "raw"), ("archive", second, "qcow2")])
          assert not marker.exists(), "rebuilt images for already installed disks"
          assert digest(source) == source_hash and digest(first) == source_hash and digest(second) == before_second

          # A later disk that cannot fit its image must not leave earlier disks overwritten.
          first = blank("batch-first.raw")
          small = blank("batch-too-small.raw", 8 * 1024 * 1024)
          before_first, before_small = digest(first), digest(small)
          provision_disks([("system", first, "raw"), ("data", small, "raw")], error="smaller than the installed image")
          assert digest(first) == before_first and digest(small) == before_small

          # Replacing a disk during batch preflight must not redirect a write.
          disk = blank("swap.raw")
          blank_hash = digest(disk)
          victim = work / "victim.raw"
          victim.write_bytes(b"unrelated data must survive\n")
          victim_hash = digest(victim)
          provision_disk(disk, error="changed after it was locked", SWAP_PATH=str(disk), SWAP_VICTIM=str(victim))
          assert disk.is_symlink() and digest(victim) == victim_hash
          assert digest(work / "swap.raw.original") == blank_hash
          print("MicroVM provisioning preserves existing disks, builds missing disks together and rejects unsafe probes/images.")
          PY
          touch "$out"
        '';
    };
  };
}

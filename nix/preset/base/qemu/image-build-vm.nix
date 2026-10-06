# Runs Disko's image builder inside a Linux VM on non-Linux hosts.
#
# The VM imports the builder's closure from NAR files in the shared build
# directory instead of mounting the host store: macOS stores rename files whose
# names differ only by case, which Linux closures contain.
{
  lib,
  nixosSystem,
  linuxSystem,
  writeShellApplication,
  coreutils,
  nix,
  vfkit,
}: let
  guest =
    (nixosSystem {
      system = linuxSystem;
      modules = [
        ({
          config,
          lib,
          pkgs,
          modulesPath,
          ...
        }: {
          imports = ["${modulesPath}/installer/netboot/netboot-minimal.nix"];
          system.stateVersion = lib.trivial.release;
          boot.kernelParams = ["console=hvc0"];
          boot.initrd.availableKernelModules = ["virtio_pci" "virtio_blk" "virtiofs"];
          # Keep imported store paths on the sparse disk instead of RAM.
          fileSystems."/nix/.rw-store" = lib.mkForce {
            device = "/dev/vda";
            fsType = "ext4";
            neededForBoot = true;
            autoFormat = true;
          };
          fileSystems."/build" = {
            device = "build";
            fsType = "virtiofs";
          };
          documentation.enable = false;
          nix.settings = {
            experimental-features = ["nix-command"];
            substituters = lib.mkForce [];
          };
          systemd.services.idr-image-build = {
            wantedBy = ["multi-user.target"];
            requires = ["build.mount"];
            after = ["build.mount" "multi-user.target"];
            path = [config.nix.package pkgs.bash pkgs.coreutils];
            serviceConfig = {
              Type = "oneshot";
              StandardOutput = "tty";
              StandardError = "tty";
              TTYPath = "/dev/hvc0";
            };
            script = ''
              status=0
              # shellcheck disable=SC2046
              nix --offline copy --no-check-sigs --from file:///build/.idr-cache $(cat /build/.idr-paths) || status=$?
              if [[ $status == 0 ]]; then
                (cd /build && bash /build/.idr-command) || status=$?
              fi
              echo "$status" > /build/.idr-exit
              systemctl poweroff --no-block
            '';
          };
        })
      ];
    }).config;
  inherit (guest.system) build;
  kernelParams = toString ([
      "init=${build.toplevel}/init"
    ]
    ++ guest.boot.kernelParams);
in
  writeShellApplication {
    name = "idr-qemu-image-build-vm";
    runtimeInputs = [coreutils nix vfkit];
    text = ''
      usage() {
        echo "Usage: idr-qemu-image-build-vm --memory MIB --build-dir DIR [--closure PATH]... -- COMMAND..." >&2
        exit 2
      }

      memory=""
      build_dir=""
      closure=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --memory) memory=$2; shift 2 ;;
          --build-dir) build_dir=$2; shift 2 ;;
          --closure) closure+=("$2"); shift 2 ;;
          --) shift; break ;;
          *) usage ;;
        esac
      done
      [[ -n $memory && -n $build_dir && $# -gt 0 ]] || usage

      build_dir=$(realpath "$build_dir")
      # shellcheck disable=SC2329
      cleanup() {
        rm -rf "$build_dir/.idr-cache" "$build_dir/.idr-store.raw" "$build_dir/.idr-paths" \
          "$build_dir/.idr-command" "$build_dir/.idr-exit" "$build_dir/.idr-console.log"
      }
      trap cleanup EXIT

      nix --offline copy --no-check-sigs --to "file://$build_dir/.idr-cache?compression=none" "''${closure[@]}"
      printf '%s\n' "''${closure[@]}" > "$build_dir/.idr-paths"
      printf '%q ' "$@" > "$build_dir/.idr-command"
      truncate -s 256G "$build_dir/.idr-store.raw"

      run_vm() {
        rm -f "$build_dir/.idr-exit" "$build_dir/.idr-console.log"
        touch "$build_dir/.idr-console.log"
        tail -n +1 -F "$build_dir/.idr-console.log" 2>/dev/null &
        local tail_pid=$!
        local status=0
        vfkit --cpus "$(nproc)" --memory "$memory" "$@" \
          --bootloader "linux,kernel=${build.kernel}/${guest.system.boot.loader.kernelFile},initrd=${build.netbootRamdisk}/initrd,cmdline=\"${kernelParams}\"" \
          --device virtio-blk,path="$build_dir/.idr-store.raw" \
          --device virtio-fs,sharedDir="$build_dir",mountTag=build \
          --device virtio-serial,logFilePath="$build_dir/.idr-console.log" \
          </dev/null || status=$?
        kill "$tail_pid" 2>/dev/null || true
        return "$status"
      }

      # Nested virtualization gives the builder's own VM KVM; older Macs lack it.
      if ! run_vm --nested && [[ ! -e $build_dir/.idr-exit ]]; then
        echo "idr-qemu-image-build-vm: nested virtualization is unavailable; the image builder will emulate its VM" >&2
        run_vm
      fi

      if [[ ! -e $build_dir/.idr-exit ]]; then
        echo "idr-qemu-image-build-vm: the image build VM stopped without a result" >&2
        exit 1
      fi
      exit "$(cat "$build_dir/.idr-exit")"
    '';
  }

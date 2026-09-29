{
  lib,
  writeShellApplication,
  runCommand,
  writers,
  coreutils,
  gitMinimal,
  iproute2,
  nix,
  nushell,
  openssl,
  openssh,
  qemu,
  sops,
  util-linuxMinimal,
  rofi,
  socat,
}: let
  scripts = ../../../scripts;
  # QEMU finds this packaged ACL beside the copied helper.
  bridgeHelper = runCommand "idr-qemu-bridge-helper" {} ''
    install -Dm755 ${qemu}/libexec/qemu-bridge-helper $out/libexec/qemu-bridge-helper
    mkdir -p $out/libexec/qemu-bundle/etc/qemu
    echo 'allow idr0' > $out/libexec/qemu-bundle/etc/qemu/bridge.conf
  '';
  networkAskpass = writers.writeNuBin "idr-qemu-network-askpass" ''
    def main [prompt: string] {
      exec ${lib.getExe rofi} -dmenu -password -input /dev/null -format s -kb-toggle-case-sensitivity "" -p $prompt
    }
  '';
  networkBootstrap = writers.writeNuBin "idr-qemu-network-bootstrap" ''
    def main [--fd: int = 0, --br: string, --use-vnet, --network-prefix: string] {
      let prefix = $network_prefix | default $env.IDR_QEMU_NETWORK_PREFIX?
      if $prefix == null or $prefix !~ '^fd[0-9a-f]{2}(:[0-9a-f]{4}){2}$' {
        error make {msg: "Invalid IDR QEMU network prefix"}
      }
      if (^${coreutils}/bin/id -u | into int) != 0 {
        print --stderr "Warning: using sudo to set up the idr0 network."
        $env.SUDO_ASKPASS = $env.SUDO_ASKPASS? | default --empty "${lib.getExe networkAskpass}"
        # Pass the prefix explicitly across sudo, which can clear the environment.
        # Preserve the helper socket and unblock QEMU's SIGCHLD mask for sudo.
        exec ${socat}/bin/socat $"FD:($fd)" $"EXEC:${coreutils}/bin/env --default-signal=CHLD sudo --askpass -- ($nu.current-exe) -n --no-std-lib --no-history ($env.CURRENT_FILE) --fd=0 --network-prefix='($prefix)',nofork"
      }

      # Another VM may have already created the bridge.
      ^${iproute2}/bin/ip link add name idr0 type bridge | complete | ignore
      ^${iproute2}/bin/ip -6 address replace $"($prefix)::1/48" dev idr0
      ^${iproute2}/bin/ip link set dev idr0 up
      ^${iproute2}/bin/ip -6 route replace $"($prefix)::/48" dev idr0 metric 256
      exec ${bridgeHelper}/libexec/qemu-bridge-helper --use-vnet --br=idr0 $"--fd=($fd)"
    }
  '';
in
  writeShellApplication {
    name = "idr-qemu-runtime";
    passthru = {inherit networkBootstrap;};
    runtimeInputs = [
      coreutils
      gitMinimal
      iproute2
      nix
      (nushell.override {
        # Stop background unlock commands when the runner receives SIGTERM.
        additionalFeatures = features: features ++ ["ctrlc/termination"];
      })
      openssl
      openssh
      qemu
      sops
      util-linuxMinimal
    ];
    text = ''
      export IDR_QEMU_NETWORK_BOOTSTRAP=${lib.escapeShellArg (lib.getExe networkBootstrap)}
      export IDR_MK_IMAGES_SCRIPT=${lib.escapeShellArg "${scripts}/idr-mk-images.nu"}
      exec nu -n --no-std-lib --no-history ${scripts}/idr-qemu.nu "$@"
    '';
  }

_: {
  lib,
  pkgs,
  ...
}: let
  scripts = ../../scripts;

  idr-wipe-local-vm =
    pkgs.writers.writeNuBin "idr-wipe-local-vm" {
      makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.qemu pkgs.flock pkgs.nix])];
    } ''
      source ${scripts}/idr-wipe-local-vm.nu
    '';

  idr-serial = pkgs.writeShellApplication {
    name = "idr-serial";
    runtimeInputs = with pkgs; [nushell socat];
    text = ''
      exec nu -n --no-std-lib --no-history ${scripts}/idr-serial.nu "$@"
    '';
  };

  idr-vnc = pkgs.writeShellApplication {
    name = "idr-vnc";
    runtimeInputs = with pkgs; [nushell tigervnc];
    text = ''
      exec nu -n --no-std-lib --no-history ${scripts}/idr-vnc.nu "$@"
    '';
  };
in {
  commands =
    [
      {
        name = "idr-wipe-local-vm";
        package = idr-wipe-local-vm;
        help = "Stop a local VM and clear its disk partition tables";
      }
      {
        name = "idr-serial";
        package = idr-serial;
        help = "Connect to a machine's QEMU serial console (IDR_SERIAL_ESCAPE=ctrl-z|ctrl-])";
      }
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      {
        name = "idr-vnc";
        package = idr-vnc;
        help = "Connect to a machine's QEMU VNC display";
      }
    ];
}

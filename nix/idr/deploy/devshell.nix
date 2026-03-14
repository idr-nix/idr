top: {
  lib,
  pkgs,
  idrSsh,
  idrNu,
  ...
}: let
  scripts = ../../scripts;

  idr-unlock-disks =
    pkgs.writers.writeNuBin "idr-unlock-disks" {
      makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.coreutils pkgs.nix pkgs.sops idrSsh])];
    } ''
      source ${scripts}/idr-unlock-disks.nu
    '';

  idr-copy-extra-files =
    pkgs.writers.writeNuBin "idr-copy-extra-files" {
      makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.coreutils pkgs.nix pkgs.sops idrSsh pkgs.openssh])];
    } ''
      source ${scripts}/idr-copy-extra-files.nu
    '';

  idr-anywhere =
    pkgs.writers.makeScriptWriter {
      interpreter = "${lib.getExe idrNu} --no-config-file";
      makeWrapperArgs = ["--prefix" "PATH" ":" (lib.makeBinPath [pkgs.coreutils pkgs.gitMinimal pkgs.nix pkgs.sops idrSsh pkgs.sshpass pkgs.nixos-anywhere])];
    } "/bin/idr-anywhere" ''
      source ${scripts}/idr-anywhere.nu
    '';

  idr-mk-images = pkgs.writeShellApplication {
    name = "idr-mk-images";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      exec ${lib.getExe idrNu} -n --no-std-lib --no-history ${scripts}/idr-mk-images.nu "$@"
    '';
  };
in {
  commands = [
    {
      name = "idr-mk-images";
      package = idr-mk-images;
      help = "Create disk images for a machine";
    }
    {
      name = "idr-unlock-disks";
      package = idr-unlock-disks;
      help = "Unlock a machine's disks over SSH";
    }
    {
      name = "idr-anywhere";
      package = idr-anywhere;
      help = "Install a deploy node using nixos-anywhere";
    }
    {
      name = "idr-copy-extra-files";
      package = idr-copy-extra-files;
      help = "Copy post-format files to a running machine";
    }
    {
      name = "deploy";
      package = top.inputs.deploy-rs.packages.${pkgs.stdenv.hostPlatform.system}.default;
      help = "Deploy machine configurations";
    }
  ];
  packages = [pkgs.qemu];
}

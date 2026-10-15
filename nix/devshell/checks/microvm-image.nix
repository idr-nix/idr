{
  pkgs,
  lib,
  machine,
  imageBuilder,
  sshHostKey,
}: let
  cfg = machine.config;
  metadata = cfg.system.build.idr.meta.disko;
  imageNames = map (disk: disk.imageName) (builtins.attrValues metadata.disks);
  manifest = pkgs.writeText "microvm-test-installation.json" (builtins.toJSON {
    inherit (metadata) preFormatFiles postFormatFiles;
    hostId = metadata.hostId or null;
    hostIdIsBigEndian = metadata.hostIdIsBigEndian or false;
  });
  prepare = pkgs.writeText "microvm-test-image.nu" ''
    use ${../../scripts/idr-common.nu} [with-disko-files]
    with-disko-files (open --raw ${manifest} | from json) {|files|
      let arguments = (
        ($files.pre_format_files | each {|file| ["--pre-format-files" $file.src $file.dst] } | flatten)
        ++ ($files.post_format_files | each {|file| ["--post-format-files" $file.src $file.dst] } | flatten)
      )
      do --capture-errors {
        run-external ${imageBuilder} "--build-memory" "4096" ...$arguments
      }
    }
  '';
  # Only public test keys enter this cached image. The storage test exercises
  # first installation; runtime tests reuse its real IDR/Disko image builder.
  image =
    pkgs.runCommand "microvm-test-images" {
      nativeBuildInputs = with pkgs; [nushell qemu-utils sops];
      SOPS_AGE_KEY_CMD = lib.escapeShellArgs ["${pkgs.ssh-to-age}/bin/ssh-to-age" "-private-key" "-i" sshHostKey];
    } ''
      export PRJ_DATA_DIR="$TMPDIR"
      mkdir image
      (
        cd image
        unset NIX_ATTRS_SH_FILE NIX_ATTRS_JSON_FILE
        nu --no-config-file --no-std-lib --no-history ${prepare}
      )
      mkdir "$out"
      ${lib.concatMapStringsSep "\n" (name: ''
          qemu-img convert -c -f raw -O qcow2 image/${lib.escapeShellArg name}.raw "$out"/${lib.escapeShellArg name}.qcow2
        '')
        imageNames}
    '';
in
  pkgs.writeShellScript "microvm-test-image-builder" ''
    set -e
    ${lib.concatMapStringsSep "\n" (name: ''
        ${pkgs.qemu-utils}/bin/qemu-img convert -f qcow2 -O raw ${image}/${lib.escapeShellArg name}.qcow2 ${lib.escapeShellArg name}.raw
      '')
      imageNames}
  ''

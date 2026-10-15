{
  lib,
  pkgs,
  unitName,
  vm,
  disks,
  machine,
  imageBuilder,
  metadata,
  sshHostKeyPath,
  zfsPackage ? null,
}: let
  installationDisks = lib.filter (disk: disk.provisioning != "none") (builtins.attrValues disks);
  suppliedDisks = lib.sort (a: b: a.path < b.path) (lib.filter (disk: disk.provisioning != "zvol") installationDisks);
  manifest = pkgs.writeText "${unitName}-installation.json" (builtins.toJSON {
    inherit unitName;
    machine = machine.config.networking.hostName;
    disks = installationDisks;
    inherit (vm.provisioning) buildMemoryMiB;
    builder = toString imageBuilder;
    metadata = {
      inherit (metadata) preFormatFiles postFormatFiles;
      hostId = metadata.hostId or null;
      hostIdIsBigEndian = metadata.hostIdIsBigEndian or false;
    };
  });
  script = pkgs.writeText "${unitName}-provision.nu" ''
    use ${../scripts/idr-common.nu} [with-disko-files]
    source ${./provision.nu}
  '';
in
  pkgs.writeShellApplication {
    name = "${unitName}-provision";
    runtimeInputs = lib.optional (lib.any (disk: disk.provisioning == "zvol") installationDisks) zfsPackage ++ (with pkgs; [bash coreutils nushell qemu-utils sops systemd util-linux]);
    text = ''
      : "''${STATE_DIRECTORY:?The installation service needs a StateDirectory}"
      umask 077
      ${lib.optionalString (sshHostKeyPath != null) ''
        export SOPS_AGE_KEY_CMD=${lib.escapeShellArg (lib.escapeShellArgs ["${pkgs.ssh-to-age}/bin/ssh-to-age" "-private-key" "-i" sshHostKeyPath])}
      ''}
      disk_fds='{'
      ${lib.concatMapStringsSep "\n" (disk: ''
          if [ -b ${lib.escapeShellArg disk.path} ] || [ -f ${lib.escapeShellArg disk.path} ]; then
            # Open read-only: acquiring the lock must never create a missing disk.
            exec {disk_fd}<${lib.escapeShellArg disk.path}
            flock --exclusive --timeout 10 "$disk_fd"
            disk_fds+=${lib.escapeShellArg (builtins.toJSON disk.name + ":")}"$disk_fd,"
          fi
        '')
        suppliedDisks}
      disk_fds="''${disk_fds%,}"
      export IDR_MICROVM_DISK_FDS="$disk_fds}"
      exec flock --exclusive --close "$STATE_DIRECTORY/provision.lock" \
        nu --no-config-file --no-std-lib --no-history ${script} ${manifest}
    '';
  }

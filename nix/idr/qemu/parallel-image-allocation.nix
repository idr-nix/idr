{
  lib,
  pkgs,
  diskDevices,
  imageFormat,
}: let
  disks = builtins.attrValues diskDevices;
  # Disko has no preVM extension option. Intercept only its preVM writer and
  # require an exact match so an upstream change fails during evaluation.
  allocation =
    lib.concatMapStringsSep "\n" (disk: "${pkgs.qemu}/bin/qemu-img create -f ${imageFormat} \"$out/${disk.imageName}.${imageFormat}\" ${disk.imageSize}")
    disks;
  # Regex matching needs a context-free needle. The replacement scripts retain
  # their package references, so the resulting builder closure stays complete.
  allocationMatch = builtins.unsafeDiscardStringContext allocation;
  jobs = map (disk:
    pkgs.writeShellScript "idr-allocate-${disk.imageName}" ''
      set -efu
      ${pkgs.qemu}/bin/qemu-img create -f ${lib.escapeShellArg imageFormat} \
        "$out"/${lib.escapeShellArg "${disk.imageName}.${imageFormat}"} ${lib.escapeShellArg disk.imageSize}
    '')
  disks;
  parallelAllocation = ''
    ${pkgs.nushell}/bin/nu -n --no-std-lib --no-history ${./parallel-jobs.nu} run \
      --bash ${pkgs.bash}/bin/bash --nproc ${pkgs.coreutils}/bin/nproc \
      -- ${lib.escapeShellArgs (map toString jobs)}
  '';
in
  if builtins.length disks < 2
  then pkgs
  else
    pkgs
    // {
      writers =
        pkgs.writers
        // {
          makeScriptWriter = settings: name: content:
            pkgs.writers.makeScriptWriter settings name (
              if name != "preVM.sh"
              then content
              else
                assert lib.assertMsg (builtins.length (lib.splitString allocationMatch content) == 2)
                "Disko preVM allocation changed; review the parallel image allocation hook";
                  lib.replaceStrings [allocationMatch] [parallelAllocation] content
            );
        };
    }

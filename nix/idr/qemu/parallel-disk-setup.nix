# Import only into Disko's temporary image partitioning configuration.
args: {
  config,
  lib,
  diskoLib,
  pkgs,
  ...
}: let
  nativePkgs = args.pkgs or pkgs;
  scheduler = "${nativePkgs.nushell}/bin/nu -n --no-std-lib --no-history ${./parallel-jobs.nu}";
  devices = config.disko.devices;
  dependencies = devices._meta.deviceDependencies or {};
  deviceTypes = lib.filterAttrs (name: _: !(lib.hasPrefix "_" name)) devices;
  sortedDevices = diskoLib.sortDevicesByDependencies dependencies deviceTypes;
  isDisk = device: builtins.head device == "disk";
  create = device: lib.getAttrFromPath (device ++ ["_create"]) devices;

  # Keep every aggregator in its original position. Only adjacent physical
  # disks are candidates for concurrent formatting.
  groups = lib.foldl' (acc: device:
    if isDisk device && acc != [] && lib.all isDisk (lib.last acc)
    then (lib.init acc) ++ [(lib.last acc ++ [device])]
    else acc ++ [[device]]) []
  sortedDevices;

  asksForPassword = content:
    content
    != null
    && (
      ((content.type or "") == "luks" && ((content.askPassword or false) || (content.enrollFido2 or false) || (content.enrollRecovery or false)))
      || asksForPassword (content.content or null)
      || lib.any (partition: asksForPassword (partition.content or null)) (builtins.attrValues (content.partitions or {}))
    );
  independent = group:
    lib.all (device:
      !(lib.any (dependency: builtins.elem dependency group)
        (lib.attrByPath device [] dependencies)))
    group;
  interactive = group:
    lib.any (device:
      asksForPassword ((lib.getAttrFromPath device devices).content or null))
    group;

  diskIndexes = lib.listToAttrs (lib.imap0 (index: name: {
    inherit name;
    value = index;
  }) (builtins.attrNames devices.disk));
  workerDirectory = device: "worker-${toString diskIndexes.${builtins.elemAt device 1}}";
  worker = device:
    nativePkgs.writeShellScript "idr-format-${lib.concatStringsSep "-" device}" ''
      set -efux
      disko_devices_dir="$IDR_DISKO_DEVICES_DIR"
      ${create device}
    '';
  plan = nativePkgs.writeText "idr-image-setup.json" (builtins.toJSON (map (group: {
      parallel = builtins.length group > 1 && lib.all isDisk group && independent group && !(interactive group);
      jobs =
        map (device: {
          script = toString (worker device);
          registry =
            if isDisk device
            then workerDirectory device
            else null;
        })
        group;
    })
    groups));
in {
  config.disko.devices = lib.mkForce {
    _create = ''
      set -efux
      # Upstream commands remain Bash; Nu receives only explicit state.
      if [[ -v rootDir ]]; then export rootDir; fi
      idr_image_setup_arguments=$(${scheduler} arguments -- "$@")
      ${scheduler} setup ${plan} \
        --bash ${nativePkgs.bash}/bin/bash \
        --nproc ${nativePkgs.coreutils}/bin/nproc \
        --mktemp ${nativePkgs.coreutils}/bin/mktemp \
        --script-args-json "$idr_image_setup_arguments"
    '';
  };
}

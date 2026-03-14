{
  projectRoot,
  projectRef ? null,
  node,
  flake ? builtins.getFlake projectRef,
}: let
  idr = flake.inputs.idr or flake;
  lib = idr.inputs.nixpkgs.lib;
  deploy = flake.deploy;
  target = deploy.nodes.${node};
  profile = target.profiles.system;
  meta = profile.path.idr.meta;
  pkgs = idr.inputs.nixpkgs.legacyPackages.${meta.system};
  settings = [profile target deploy];
  sshUsers = builtins.filter (user: user != null) (map (settings: settings.sshUser or null) settings);
  sourcePrefix = "${flake.outPath}/";
  sourceFile = file:
    if file != null && lib.hasPrefix sourcePrefix (toString file)
    then "${projectRoot}/${lib.removePrefix sourcePrefix (toString file)}"
    else null;
  diskKey = meta.disko.preFormatFiles."/disk-key.txt" or null;
in {
  inherit meta pkgs profile;

  target = {
    projectHash = flake.narHash;
    inherit (meta) machine system sshHostPublicKey initrdHostPublicKey initrdHostPublicKeys initrdPort;
    inherit (target) hostname;
    sshUser =
      if sshUsers == []
      then null
      else builtins.head sshUsers;
    sshOpts = lib.concatMap (settings: settings.sshOpts or []) settings;
    fastConnection = lib.findFirst (value: value != null) false (map (settings: settings.fastConnection or null) settings);
    inherit diskKey;
    disks = map (disk: disk.path) (builtins.attrValues meta.disko.disks);
    inherit (meta.disko) preFormatFiles postFormatFiles;
    sopsFile = meta.defaultSopsFile;
    sourceSopsFile = sourceFile meta.defaultSopsFile;
    sourceDiskKeyFile = sourceFile (
      if diskKey == null
      then null
      else diskKey.sopsFile
    );
    qemu =
      if profile.path.idr.qemuProcess != null
      then {
        process = profile.path.idr.qemuProcess;
        inherit (meta) machine;
        disks = builtins.attrValues meta.disko.disks;
      }
      else null;
  };
}

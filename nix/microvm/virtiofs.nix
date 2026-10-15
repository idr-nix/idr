{
  lib,
  runtimeDirectory,
  shares,
}:
lib.mapAttrsToList (tag: share: {
  inherit tag;
  inherit (share) source cache readOnly;
  proto = "virtiofs";
  socket = "${runtimeDirectory}/fs-${tag}.sock";
  dax = false;
  posixAcl = true;
  extraArgs = [];
})
shares

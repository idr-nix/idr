top: moduleArgs @ {
  inputs,
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.idr.preset;
in {
  imports = top.idr-lib.importApplyAll top [
    ./impermanence/impermanence.nix
    ./loopback/loopback.nix
    ./base/base.nix
  ];
}

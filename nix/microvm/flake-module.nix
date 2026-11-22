top: {lib, ...}: {
  flake.modules.nixos.microvm = lib.modules.importApply ./nixos-module.nix top;
  flake.modules.nixos.microvm-guest = lib.modules.importApply ./guest.nix top;

  # Both follow their main branch.
  perSystem = {pkgs, ...}: {
    idr.packages = {
      cloud-hypervisor = {
        package = pkgs.callPackage ./cloud-hypervisor.nix {};
        update = pkgs.writeShellScript "update-cloud-hypervisor" ''
          exec ${lib.getExe pkgs.nix-update} --flake cloud-hypervisor --version=branch
        '';
      };
      hypeman-memory = {
        package = pkgs.callPackage ./hypeman-package.nix {};
        # Numbered releases only; hypeman also has tags such as demo-2026-03-06.
        update = pkgs.writeShellScript "update-hypeman-memory" ''
          exec ${lib.getExe pkgs.nix-update} --flake hypeman-memory --version=branch \
            --version-regex '^v?([0-9][0-9.]*-unstable-.*)$'
        '';
      };
    };
  };
}

top: {lib, ...}: {
  imports = top.idr-lib.importApplyAll top [
    ./checks/connectivity.nix
    ./checks/isolation.nix
    ./checks/link.nix
    ./checks/lifecycle.nix
    ./checks/psk.nix
    ./checks/publish.nix
    ./checks/transport.nix
  ];

  flake.modules = {
    nixos.mesh = lib.modules.importApply ./nixos-module.nix top;
    service.mesh = lib.modules.importApply ./service-module.nix top;
  };

  perSystem = {
    config,
    pkgs,
    system,
    ...
  }:
    lib.optionalAttrs (builtins.elem system ["x86_64-linux" "aarch64-linux"]) {
      packages = {
        idr-mesh = pkgs.callPackage ./. {};
      };

      devshells.default = let
        haskellPackages = pkgs.callPackage ./package-set.nix {};
        deps = config.packages.idr-mesh.getCabalDeps;
      in {
        packages = [
          (haskellPackages.ghcWithPackages (_: deps.setupHaskellDepends ++ deps.executableHaskellDepends))
          pkgs.haskellPackages.haskell-language-server
          # HLS loads the package with cabal, whose custom setup runs agda.
          pkgs.cabal-install
          (lib.getBin pkgs.haskellPackages.Agda)
        ];
        env = [
          {
            name = "LIBRARY_PATH";
            prefix = lib.makeLibraryPath deps.executableSystemDepends;
          }
        ];
      };
    };
}

top: {lib, ...}: {
  defaults = {pkgs, ...}: {
    nix = {
      package = top.inputs.determinate-nix.packages.${pkgs.stdenv.hostPlatform.system}.nix-cli;
      settings = {
        experimental-features = ["nix-command" "flakes" "parallel-eval"];
        eval-cores = 12;
        lazy-trees = true;
        sandbox = true;
        sandbox-fallback = false;
        substituters = lib.mkForce [];
      };
    };
  };
}

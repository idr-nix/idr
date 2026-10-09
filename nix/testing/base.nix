top: {
  imports = with top.self.modules.nixosTest; [nix nix-store direnv kvm-clock];
}

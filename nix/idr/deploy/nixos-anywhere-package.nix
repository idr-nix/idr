{nixos-anywhere}:
nixos-anywhere.overrideAttrs (old: {
  patches = (old.patches or []) ++ [./nixos-anywhere-ssh-store-setting.patch];
})

{
  lib,
  machineId,
  networkPrefix,
}: let
  machine = lib.concatStringsSep ":" (lib.genList (i: builtins.substring (i * 4) 4 machineId) 3);
in {
  network = {
    description = "Configure local QEMU networking";
    wantedBy = ["sysinit.target"];
    before = ["systemd-networkd.service"];
    unitConfig = {
      DefaultDependencies = false;
      ConditionCredential = "idr.workspace-id";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ImportCredential = ["idr.workspace-id" "idr.network-prefix-length"];
    };
    script = ''
      workspace=$(< "$CREDENTIALS_DIRECTORY/idr.workspace-id")
      prefix_length=$(< "$CREDENTIALS_DIRECTORY/idr.network-prefix-length")

      mkdir -p /run/systemd/network
      cat > /run/systemd/network/01-idr-qemu.network <<EOF
      [Match]
      Name=eno1
      Driver=virtio_net

      [Network]
      Address=${networkPrefix}:''${workspace:0:4}:''${workspace:4:4}:${machine}/$prefix_length
      DHCP=no
      LinkLocalAddressing=ipv6
      IPv6AcceptRA=no
      EOF

      if systemctl is-active --quiet systemd-networkd.service; then
        networkctl reload
      fi
    '';
  };

  ssh = {
    description = "Authorize the local QEMU SSH key";
    wantedBy = ["sshd.service"];
    before = ["sshd.service"];
    unitConfig = {
      ConditionCredential = ["idr.workspace-id" "idr.qemu-ssh-key"];
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ImportCredential = ["idr.qemu-ssh-key"];
      RuntimeDirectory = "idr-qemu-ssh";
      RuntimeDirectoryMode = "0700";
    };
    script = ''
      printf '%s\n' "$(< "$CREDENTIALS_DIRECTORY/idr.qemu-ssh-key")" > "$RUNTIME_DIRECTORY/root"
      chmod 0600 "$RUNTIME_DIRECTORY/root"
    '';
  };
}

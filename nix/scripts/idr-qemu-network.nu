use idr-common.nu [workspace-id]

export def address [prefix: string, workspace_id: string, machine_id: string] {
  let suffix = $"($workspace_id)($machine_id)" | split chars | chunks 4 | each { str join } | str join ":"
  $"($prefix):($suffix)"
}

export def options [] {
  let workspace_id = workspace-id
  let mac_address = random binary 5 | encode hex --lower | split chars | chunks 2 | each { str join } | prepend "02" | str join ":"
  let backend = match $nu.os-info.name {
    linux => {
      let bridge = ^ip -json -6 address show dev idr0 to $"($env.IDR_QEMU_NETWORK_PREFIX)::1/128" | complete
      let route = ^ip -6 route show dev idr0 exact $"($env.IDR_QEMU_NETWORK_PREFIX)::/48" | complete
      let ready = $bridge.exit_code == 0 and $route.exit_code == 0 and ($route.stdout | is-not-empty) and (
        $bridge.stdout | from json | any {|link|
          "UP" in $link.flags and ($link.addr_info | any {|address| $address.local? != null})
        }
      )
      let helper = if $ready {
        (
          $env.IDR_QEMU_BRIDGE_HELPER?
          | default (
            which qemu-bridge-helper /usr/lib/qemu/qemu-bridge-helper /usr/libexec/qemu-bridge-helper
            | get -o 0.path
          )
          | default $env.IDR_QEMU_NETWORK_BOOTSTRAP
        )
      } else {
        $env.IDR_QEMU_NETWORK_BOOTSTRAP
      }
      # QEMU invokes a shell when the helper path contains spaces or tabs.
      let helper = if $helper =~ '[ \t]' {
        "'" + ($helper | str replace --all "'" "'\\''") + "'"
      } else {
        $helper
      } | str replace --all "," ",,"
      {
        options: $"bridge,id=idr-local,br=idr0,helper=($helper)"
        prefix_length: 48
      }
    }
    macos => {
      options: $"vmnet-shared,id=idr-local,nat66-prefix=($env.IDR_QEMU_NETWORK_PREFIX):($workspace_id | str substring 0..<4)::/64"
      prefix_length: 64
    }
  }
  [
    "-netdev" $backend.options
    "-device" $"virtio-net-pci,netdev=idr-local,mac=($mac_address),acpi-index=1"
    "-fw_cfg" $"name=opt/io.systemd.credentials/idr.workspace-id,string=($workspace_id)"
    "-fw_cfg" $"name=opt/io.systemd.credentials/idr.network-prefix-length,string=($backend.prefix_length)"
  ]
}

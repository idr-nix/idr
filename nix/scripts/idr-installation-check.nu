def inspect-target [connection: record, command: list<string>] {
  let command = $command | each {|argument|
    $"'($argument | str replace --all "'" "'\\''")'"
  } | str join " "
  let result = if $connection.env_password {
    sshpass -e ssh -T ...$connection.arguments $command | complete
  } else {
    ssh -T ...$connection.arguments $command | complete
  }
  if $result.exit_code != 0 {
    error make {msg: $"Could not inspect the installation target: ($result.stderr | str trim)"}
  }
  $result.stdout
}

def descendants [device: record] {
  [$device] ++ ($device.children? | default [] | each {|child| descendants $child } | flatten)
}

def filesystem-active [connection: record, filesystem: string] {
  if $filesystem == "zfs_member" {
    if "zfs" not-in (inspect-target $connection ["ls" "-1" "/sys/module"] | lines) {
      return false
    }
    inspect-target $connection ["zpool" "list" "-H" "-o" "name"] | str trim | is-not-empty
  } else {
    let mounted = inspect-target $connection ["findmnt" "--json" "--list" "--output" "FSTYPE"]
      | from json | get filesystems | get fstype
    $filesystem in $mounted
  }
}

export def installation-status [arguments: list<string>, disks: list<string>, --env-password] {
  if ($disks | is-empty) {
    error make {msg: "No target disks are configured."}
  }
  let connection = {arguments: $arguments, env_password: $env_password}
  let os = inspect-target $connection ["cat" "/etc/os-release"]
    | lines | parse -r '^ID=(?<id>.+)$' | get id | first
    | str trim --char '"' | str trim --char "'"

  let swap_files = inspect-target $connection ["swapon" "--show=NAME,TYPE" "--raw" "--noheadings"]
    | lines | parse -r '^(?<name>.+) (?<type>[^ ]+)$' | where type == file
  let swap_devices = $swap_files | each {|swap|
    # swapon's raw output escapes whitespace and backslashes as \xNN.
    let path = $swap.name | str replace --all "%" "%25"
      | str replace --all --regex '\\x([0-9a-fA-F]{2})' '%$1' | url decode
    inspect-target $connection ["findmnt" "--json" "--output" "MAJ:MIN" "--target" $path]
      | from json | get filesystems | get "maj:min"
  } | flatten

  let used = $disks | each {|disk|
    let devices = inspect-target $connection [
      "lsblk" "--json" "--paths" "--output" "NAME,MAJ:MIN,TYPE,FSTYPE,MOUNTPOINTS" "--" $disk
    ] | from json | get blockdevices
    if ($devices | is-empty) {
      error make {msg: $"Target disk ($disk) was not found."}
    }
    let devices = $devices | each {|device| descendants $device } | flatten
    if ($devices | any {|device|
      ($device."maj:min" in $swap_devices
        or ($device.mountpoints | any {|mount| $mount != null and $mount != "" })
        or $device.type not-in [disk part loop rom])
    }) {
      $disk
    } else if ($devices | get fstype | uniq | where $it in [zfs_member btrfs bcachefs]
      | any {|filesystem| filesystem-active $connection $filesystem }) {
      # lsblk does not show which filesystem a multi-device member belongs to,
      # so treat the disk as in use and require the stronger confirmation.
      $disk
    }
  }
  {os: $os, used: $used}
}

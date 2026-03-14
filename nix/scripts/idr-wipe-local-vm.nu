const script_path = path self

use idr-common.nu [host-data-dir host-socket-prefix]
use idr-qemu-disks.nu [read-image]
use idr-target.nu [resolve-target]

def main [node: string] {
  let target = resolve-target $node
  let qemu = $target.qemu?
  if $qemu == null or $qemu.process != $node {
    error make {msg: $"Deploy node ($node) is not a local QEMU VM."}
  }

  let data_dir = $env.PRJ_DATA_DIR | path expand | path join (host-data-dir | path basename)
  let qemu_dir = $data_dir | path join $qemu.machine "qemu"
  if ($qemu_dir | path dirname | path dirname) != $data_dir or ($qemu_dir | path expand) != $qemu_dir {
    error make {msg: $"The VM image directory must be inside ($data_dir) without symbolic links."}
  }
  let images = $qemu.disks | each {|disk|
    let image = $qemu_dir | path join $"($disk.imageName).qcow2"
    if ($image | path dirname) != $qemu_dir or ($image | path expand) != $image {
      error make {msg: $"Refusing to wipe an image outside the VM directory: ($image)"}
    }
    $image
  } | where {|image| $image | path exists }
  if ($images | is-empty) {
    print $"No local disk images exist for ($node)."
    return
  }

  if "IDR_WIPE_LOCAL_VM_LOCK_HELD" not-in $env {
    if ($env.PC_SOCKET_PATH? | default "" | path exists) {
      let state = idr process get $qemu.process -o json | complete
      if $state.exit_code != 0 {
        error make {msg: $"Could not inspect process ($qemu.process): ($state.stderr | str trim)"}
      }
      if ($state.stdout | from json | any {|process| $process.is_running }) {
        do --capture-errors { idr process stop $qemu.process }
      }
    }
    with-env {IDR_WIPE_LOCAL_VM_LOCK_HELD: "1"} {
      do --capture-errors {
        (run-external "flock" "--close" "--timeout" "30"
          ($qemu_dir | path join ".idr-qemu.lock")
          $nu.current-exe "-n" "--no-std-lib" "--no-history" $script_path $node)
      }
    }
    return
  }

  # Inspect every image before changing any of them. QEMU also checks its own image lock.
  let tables = $images | each {|image|
    if ($image | path type) != "file" {
      error make {msg: $"The VM disk image is not a regular file: ($image)"}
    }
    let result = qemu-img info --output=json -f qcow2 $image | complete
    if $result.exit_code != 0 {
      error make {msg: $"Could not inspect ($image): ($result.stderr | str trim)"}
    }
    let info = $result.stdout | from json
    if $info.format-specific.data.data-file? != null {
      error make {msg: $"Refusing to wipe an image with an external data file: ($image)"}
    }
    let size = $info.virtual-size
    let headers = [512 ($size - 512)] | uniq | where {|offset|
      (read-image $image $offset 8) == ("EFI PART" | encode utf-8)
    }
    {image: $image, offsets: ([0] ++ $headers)}
  }

  for table in $tables {
    # Clear the MBR and both GPT headers, leaving partition contents untouched.
    let commands = $table.offsets | each {|offset| ["-c" $"write -z -q ($offset) 512"] } | flatten
    let result = qemu-io -f qcow2 ...$commands -c flush $table.image | complete
    if $result.exit_code != 0 {
      error make {msg: $"Could not clear partition tables in ($table.image): ($result.stderr | str trim)"}
    }
    print $"Cleared partition tables in ($table.image)"
  }
  rm --force ($env.PRJ_DATA_DIR | path join $"(host-socket-prefix 'ssh').known_hosts")
}

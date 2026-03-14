use idr-common.nu [host-data-dir]

def main [
  machine_name: string # Machine whose running QEMU VNC display to open.
] {
  if ("PRJ_DATA_DIR" not-in $env) or ($env.PRJ_DATA_DIR | is-empty) {
    print --stderr "idr-vnc: PRJ_DATA_DIR environment variable is required."
    exit 1
  }

  let machine_name_regex = "^[a-zA-Z0-9]([a-zA-Z0-9\\-_]*[a-zA-Z0-9])?$"

  if $machine_name !~ $machine_name_regex {
    print --stderr $"idr-vnc: machine name should match regex ($machine_name_regex)"
    exit 1
  }

  let vnc_socket = (
    host-data-dir
    | path join "machine" $machine_name "qemu" "vnc.sock"
    | path expand
  )

  if not ($vnc_socket | path exists) {
    print --stderr $"idr-vnc: VNC display for ($machine_name) is not available."
    print --stderr "idr-vnc: enable VNC for the machine, start the VM, then retry."
    exit 1
  }

  print --stderr $"Connecting to ($machine_name)."
  cd ($vnc_socket | path dirname)
  exec vncviewer -Shared ./vnc.sock
}

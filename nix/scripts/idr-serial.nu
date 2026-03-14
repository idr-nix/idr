use idr-common.nu [host-data-dir]

def main [
  machine_name: string # Machine whose running QEMU serial console to attach to.
] {
  if ("PRJ_DATA_DIR" not-in $env) or ($env.PRJ_DATA_DIR | is-empty) {
    print --stderr "idr-serial: PRJ_DATA_DIR environment variable is required."
    exit 1
  }

  let machine_name_regex = "^[a-zA-Z0-9]([a-zA-Z0-9\\-_]*[a-zA-Z0-9])?$"

  if $machine_name !~ $machine_name_regex {
    print --stderr $"idr-serial: machine name should match regex ($machine_name_regex)"
    exit 1
  }

  let socket_dir = (
    host-data-dir
    | path join "machine" $machine_name "qemu"
    | path expand
  )
  let serial_socket = $socket_dir | path join "serial.sock"

  if not ($serial_socket | path exists) {
    print --stderr $"idr-serial: serial console for ($machine_name) is not available."
    print --stderr "idr-serial: start the VM first, then retry."
    exit 1
  }

  let configured_escape = if ("IDR_SERIAL_ESCAPE" in $env) and (not ($env.IDR_SERIAL_ESCAPE | is-empty)) {
    $env.IDR_SERIAL_ESCAPE | str downcase
  } else {
    "ctrl-z"
  }
  let escape = match $configured_escape {
    "ctrl-z" => {label: "Ctrl-Z", code: "0x1a"}
    "ctrl-]" => {label: "Ctrl-]", code: "0x1d"}
    _ => {
      print --stderr "idr-serial: IDR_SERIAL_ESCAPE must be ctrl-z or ctrl-]."
      exit 2
    }
  }

  print --stderr $"Connecting to ($machine_name). Press ($escape.label) to disconnect."
  cd $socket_dir
  exec socat $"STDIO,rawer,escape=($escape.code)" "UNIX-CONNECT:./serial.sock"
}

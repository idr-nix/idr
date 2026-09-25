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

  let grab_key = if ("IDR_VNC_GRAB_KEY" in $env) and (not ($env.IDR_VNC_GRAB_KEY | is-empty)) {
    $env.IDR_VNC_GRAB_KEY
  } else {
    "Insert"
  }
  let grab_keysym = (
    open --raw $env.IDR_VNC_KEYSYMS
    | lines
    | parse --regex '^#define XKB_KEY_(?<name>\S+)\s+0x(?<code>[0-9a-fA-F]+)\b'
    | where name == $grab_key
  )

  if ($grab_keysym | is-empty) {
    print --stderr $"idr-vnc: IDR_VNC_GRAB_KEY must be an X keysym name such as Insert or Pause, got ($grab_key)."
    exit 2
  }

  let grab_keyval = $grab_keysym | first | get code | into int --radix 16

  # Remmina reads preferences only from XDG_CONFIG_HOME, so give it a private one
  # that still links the user's other settings, such as GTK and dconf.
  let user_config_dir = if ("XDG_CONFIG_HOME" in $env) and (not ($env.XDG_CONFIG_HOME | is-empty)) {
    $env.XDG_CONFIG_HOME
  } else {
    $nu.home-dir | path join ".config"
  }
  let tmp_dir = mktemp --directory --tmpdir idr-vnc.XXXXXXXX

  try {
    let config_dir = $tmp_dir | path join "config"
    mkdir ($config_dir | path join "remmina")

    if ($user_config_dir | path exists) {
      ls --all --full-paths $user_config_dir
      | where {|entry| ($entry.name | path basename) != "remmina"}
      | each {|entry| ^ln -s $entry.name ($config_dir | path join ($entry.name | path basename))}
    }

    [
      "[remmina_pref]"
      $"hostkey=($grab_keyval)"
      $"shortcutkey_grab=($grab_keyval)"
    ] | str join "\n" | save ($config_dir | path join "remmina" "remmina.pref")

    let profile = $tmp_dir | path join $"($machine_name).remmina"
    [
      "[remmina]"
      $"name=($machine_name)"
      "protocol=VNC"
      # Remmina needs an absolute socket path; resolve it through the working directory
      # to stay within the Unix socket path limit, like idrQemu's relative path.
      "server=unix:///proc/self/cwd/vnc.sock"
      "keyboard_grab=1"
      "colordepth=32"
      "quality=9"
    ] | str join "\n" | save $profile

    print --stderr $"Connecting to ($machine_name). Press ($grab_key) to toggle the keyboard grab."
    cd ($vnc_socket | path dirname)
    with-env {XDG_CONFIG_HOME: $config_dir} {
      # A separate application ID keeps this Remmina apart from any already running.
      (^remmina
        $"--gapplication-app-id=org.remmina.Remmina.idr_vnc_($nu.pid)"
        --no-tray-icon
        --disable-news
        --disable-stats
        --connect $profile)
    }
    null
  } finally {|error|
    rm --recursive --force $tmp_dir
    if $error != null {
      error make $error
    }
  }
}

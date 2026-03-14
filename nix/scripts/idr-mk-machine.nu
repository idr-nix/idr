use idr-common.nu [host-data-dir]

def --wrapped main [
  --recreate (-r) # Recreate the generated machine configuration and setup keys.
  --help (-h) # Display the help message for this command.
  machine_name: string # Machine name; lowercase and dash-separated is recommended.
  ...copier_args # Additional arguments forwarded to Copier.
] {
  if "PRJ_ROOT" not-in $env {
    print "PRJ_ROOT environment variable is required."
    exit 1
  }

  let regex = "^[a-zA-Z0-9]([a-zA-Z0-9\\-_]*[a-zA-Z0-9])?$"

  if $machine_name !~ $regex {
    print $"Machine name should match regex ($regex)"
    exit 1
  }

  cd $env.PRJ_ROOT

  if $recreate {
    let machine_dir = $env.PRJ_ROOT | path join "nix" "machine" $machine_name

    if ($machine_dir | path exists) {
      print $"Removing existing machine directory: ($machine_dir)"
      rm -rf $machine_dir
    }

    if "PRJ_DATA_DIR" in $env {
      let data_machine_dir = host-data-dir | path join "machine" $machine_name

      if ($data_machine_dir | path exists) {
        print $"Removing existing machine data: ($data_machine_dir)"
        rm -rf $data_machine_dir
      }

      let host_key_dir = $env.PRJ_DATA_DIR | path join "machine-host-key"

      if ($host_key_dir | path exists) {
        let key_paths = [
          ($host_key_dir | path join $machine_name)
          ($host_key_dir | path join $"($machine_name).pub")
        ]

        $key_paths | where {|it| $it | path exists} | each {|it|
          print $"Removing key: ($it)"
          rm -f $it
        }
      }
    }
  }

  run-external copier copy "--trust" ($env.TEMPLATES_DIR | path join "machine") nix/machine "-d" $"name=($machine_name)" ...($copier_args)
}

const script_path = path self

use idr-common.nu [host-data-dir]

def ipv4-number [address: string] {
  if $address !~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' {
    error make {msg: $"Invalid IPv4 address: ($address)"}
  }
  let octets = $address | split row "." | into int
  if ($octets | any {|octet| $octet > 255}) {
    error make {msg: $"Invalid IPv4 address: ($address)"}
  }
  $octets | reduce --fold 0 {|octet, result| $result * 256 + $octet}
}

def microvm-ipv4-address [machine_name: string] {
  let idr_args = if $env.IDR_PATH? != null { ["--override-input" "idr" $env.IDR_PATH] } else { [] }
  let evaluated = nix eval --offline --json --no-write-lock-file ...$idr_args .#idrMicrovm | complete
  if $evaluated.exit_code != 0 {
    error make {msg: $"Could not read .#idrMicrovm. Update the project's IDR input to a version with MicroVM networking and make its inputs available locally.\n($evaluated.stderr | str trim)"}
  }
  let project = $evaluated.stdout | from json
  let subnet = $project.network.ipv4Subnet
  let parts = $subnet | split row "/"
  if ($parts | length) != 2 or $parts.1 !~ '^[0-9]{1,2}$' {
    error make {msg: $"Invalid MicroVM IPv4 subnet: ($subnet)"}
  }
  let prefix = $parts.1 | into int
  if $prefix > 30 {
    error make {msg: "MicroVM IPv4 subnet must have a prefix length from 0 to 30."}
  }
  let first = ipv4-number $parts.0
  let size = 2 ** (32 - $prefix)
  if $first mod $size != 0 {
    error make {msg: $"MicroVM IPv4 subnet must use its network address: ($subnet)"}
  }
  let last = $first + $size - 1
  let used = $project.machines | reject -o $machine_name | values
    | get ipv4Address | compact | each {|address| ipv4-number $address} | uniq | sort
  let current = $project.machines | get -o $machine_name | get -o ipv4Address
  if $current != null {
    let address = ipv4-number $current
    if $address > $first + 1 and $address < $last and $address not-in $used {
      return $current
    }
  }

  # Reserve the network, broadcast and host gateway (the first usable address).
  mut address = $first + 2
  for occupied in $used {
    if $occupied < $address { continue }
    if $occupied != $address { break }
    $address += 1
  }
  if $address >= $last {
    error make {msg: $"No free MicroVM IPv4 addresses in ($subnet)."}
  }
  let chosen = $address
  [24 16 8 0] | each {|shift| ($chosen // (2 ** $shift)) mod 256} | str join "."
}

def --wrapped main [
  --recreate (-r) # Recreate the generated machine configuration and setup keys.
  --system (-s): string = "x86_64-linux" # Nix system of the machine.
  --template (-t): string = "machine" # Machine template: machine or microvm.
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

  if $template not-in ["machine" "microvm"] {
    error make {msg: "Machine template must be machine or microvm."}
  }

  cd $env.PRJ_ROOT

  if $template == "microvm" and $env.IDR_MK_MACHINE_INTERNAL_LOCKED? != $env.PRJ_ROOT {
    # Use a separate lock: Copier's setup tasks also acquire the project lock.
    mkdir $env.PRJ_DATA_DIR
    $env.IDR_MK_MACHINE_INTERNAL_LOCKED = $env.PRJ_ROOT
    let arguments = (["--system" $system "--template" $template]
      ++ (if $recreate { ["--recreate"] } else { [] }) ++ [$machine_name] ++ $copier_args)
    exec flock --close --timeout 30 ($env.PRJ_DATA_DIR | path join ".idr-mk-machine.lock") $nu.current-exe -n --no-std-lib --no-history $script_path ...$arguments
  }

  # Read the current assignment before --recreate removes the machine.
  let network_args = if $template == "microvm" {
    ["-d" $"ipv4_address=(microvm-ipv4-address $machine_name)"]
  } else { [] }

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

  run-external copier copy "--trust" ($env.TEMPLATES_DIR | path join "machine") nix/machine "-d" $"name=($machine_name)" "-d" $"system=($system)" "-d" $"template=($template)" ...$network_args ...($copier_args)
}

const installation_file = path self | path dirname | path join "idr-anywhere.nix"

use idr-common.nu [with-disko-files]
use idr-target.nu [resolve-target ssh-arguments remember-host-key]
use idr-installation-check.nu [installation-status]

def installation-options [arguments: list<string>] {
  mut ssh = []
  mut anywhere = []
  mut env_password = false
  mut identity_file = null
  mut generates_hardware = false
  mut index = 0
  while $index < ($arguments | length) {
    let option = $arguments | get $index
    if $option in [--target-host --flake -f --store-paths -s --disko-mode] {
      error make {msg: $"idr-anywhere resolves ($option) from the deploy node; it cannot be overridden."}
    }
    # Group native option values so a value beginning with '-' remains a value.
    let count = if $option in [--ssh-store-setting --chown --disk-encryption-keys --option --generate-hardware-config] {
      3
    } else if $option in [--ssh-option -i -p --ssh-port --kexec --kexec-extra-flags --post-kexec-ssh-port --build-on --extra-files --phases --from] {
      2
    } else {
      1
    }
    let current = $arguments | skip $index | first $count
    if ($current | length) != $count {
      error make {msg: $"Missing value for ($option)."}
    }
    match $option {
      "--ssh-option" => { $ssh = $ssh ++ ["-o" $current.1] }
      "-p" | "--ssh-port" => { $ssh = $ssh ++ ["-p" $current.1] }
      "-i" => {
        $identity_file = $current.1
        $ssh = $ssh ++ $current
        $anywhere = $anywhere ++ $current
      }
      "--env-password" => {
        $env_password = true
        $anywhere = $anywhere ++ $current
      }
      "--generate-hardware-config" => {
        $generates_hardware = true
        $anywhere = $anywhere ++ $current
      }
      _ => { $anywhere = $anywhere ++ $current }
    }
    $index += $count
  }
  {ssh: $ssh, anywhere: $anywhere, env_password: $env_password, identity_file: $identity_file, generates_hardware: $generates_hardware}
}

def installation-ssh-config [arguments: list<string>, directory: path] {
  let result = ssh -G -T ...$arguments | complete
  if $result.exit_code != 0 {
    error make {msg: $"Could not determine the SSH configuration: ($result.stderr | str trim)"}
  }
  let settings = $result.stdout | lines | parse -r '^(?<name>[^ ]+) (?<value>.*)$'
  let connection = $settings | where name in [host user port] | transpose --as-record --header-row

  let options = $env.SSH_OPTS? | default "" | $"[($in)]" | from nuon
  let options = $options ++ $arguments
  let original_config = $options | enumerate | reduce --fold null {|option, config|
    if $option.item == "-F" {
      $options | get ($option.index + 1)
    } else if ($option.item | str starts-with "-F") {
      $option.item | str substring 2..
    } else {
      $config
    }
  }
  let includes = if $original_config == null {
    ["~/.ssh/config" "/etc/ssh/ssh_config"]
  } else if $original_config == "none" {
    []
  } else {
    [$original_config | path expand]
  }
  let defaults = with-env {SSH_OPTS: ""} {
    ssh -G -T ...(if $original_config != null { ["-F" $original_config] } else { [] }) $connection.host | complete
  }
  if $defaults.exit_code != 0 {
    error make {msg: $"Could not read the SSH configuration: ($defaults.stderr | str trim)"}
  }
  let defaults = $defaults.stdout | lines | parse -r '^(?<name>[^ ]+) (?<value>.*)$'
  let environment = $settings | where name == setenv | get value
  let default_environment = $defaults | where name == setenv | get value

  # Keep the complete values out of nixos-anywhere's whitespace-split NIX_SSHOPTS.
  let config = $directory | path join "ssh_config" | path expand
  [
    $"Host ($connection.host | to json --raw)"
    ...($settings
      | where {|setting| $setting not-in $defaults}
      # nixos-anywhere changes the login user and port after kexec and controls host verification.
      | where name not-in [host user port userknownhostsfile globalknownhostsfile stricthostkeychecking setenv]
      | each {|setting|
        # ssh -G leaves file and socket paths unquoted.
        let value = if $setting.name in [identityfile identityagent certificatefile pkcs11provider securitykeyprovider revokedhostkeys xauthlocation controlpath] {
          $setting.value | to json --raw
        } else {
          $setting.value
        }
        $"  ($setting.name) ($value)"
      })
    # OpenSSH uses only the first SetEnv directive, so retain every assignment together.
    ...(if $environment != $default_environment {
      [$"  SetEnv ($environment | each { to json --raw } | str join ' ')"]
    } else { [] })
    "Host *"
    # Preserve Match commands and the configuration for any ProxyJump hosts.
    ...($includes | each {|file| $"  Include ($file | to json --raw)"})
  ] | str join "\n" | $"($in)\n" | save --force $config

  let checked = ssh -G -T -F $config $connection.host | complete
  if $checked.exit_code != 0 {
    error make {msg: $"Could not prepare the installation SSH configuration: ($checked.stderr | str trim)"}
  }
  {config: $config, user: $connection.user, port: $connection.port}
}

def with-installation-flake [node: string, target: record, directory: path, callback: closure, --live-project] {
  let directory = $directory | path expand --strict | path join "installation"
  let project_root = $env.PRJ_ROOT | path expand --strict
  let relative_directory = if $live_project {
    try { $directory | path relative-to $project_root } catch {
      error make {msg: "Hardware report generation requires PRJ_DATA_DIR inside the project directory."}
    }
  }
  let project_ref = if $live_project {
    let parent = $relative_directory | path split | each { ".." } | path join
    $"path:($parent)"
  } else {
    $"git+file://($project_root | url encode)?narHash=($target.projectHash | url encode)"
  }
  let flake_ref = if $live_project {
    $"git+file://($project_root | url encode)?dir=($relative_directory | url encode)"
  } else {
    $"path:($directory)"
  }
  let public_files = [flake.nix target.json idr-anywhere.nix idr-target.nix flake.lock]
    | each {|file| $directory | path join $file }

  try {
    mkdir $directory
    cp $installation_file ($directory | path join "idr-anywhere.nix")
    cp ($installation_file | path dirname | path join "idr-target.nix") ($directory | path join "idr-target.nix")
    {node: $node, projectRoot: $project_root, expectedDisks: $target.disks}
      | to json | save ($directory | path join "target.json")
    '
{
  inputs.project.url = "@project@";
  outputs = { project, ... }: {
    nixosConfigurations.install.config = import ./idr-anywhere.nix
      ((builtins.fromJSON (builtins.readFile ./target.json)) // { flake = project; });
  };
}
' | str replace "@project@" $project_ref | save ($directory | path join "flake.nix")

    if $live_project {
      # Only public helper files enter the Git source; decrypted files stay ignored.
      git --literal-pathspecs -C $project_root add --intent-to-add --force -- ...($public_files | first 4)
    }
    # An explicit output leaves Git staging to us, including inside ignored .data.
    let locked = nix flake lock --allow-dirty-locks --output-lock-file ($directory | path join "flake.lock") $flake_ref | complete
    if $locked.exit_code != 0 {
      error make {msg: $"Could not prepare the installation flake for ($node): ($locked.stderr | str trim)"}
    }
    if $live_project {
      git --literal-pathspecs -C $project_root add --intent-to-add --force -- ($public_files | last)
    }
    do $callback $"($flake_ref)#install"
    null
  } finally {|error|
    if $live_project {
      git --literal-pathspecs -C $project_root rm --cached --force --ignore-unmatch --quiet -- ...$public_files
    }
    if $error != null {
      error make $error
    }
  }
}

def confirm-installation [required: list<string>, allowed: list<string>, non_interactive: bool] {
  let missing = $required | where {|confirmation| $confirmation not-in $allowed }
  if ($missing | is-empty) {
    return
  }
  if $non_interactive or not (is-terminal --stdin) {
    error make {msg: $"Missing confirmations: ($missing | str join ','). Use --allow ($required | str join ',')."}
  }
  for confirmation in $missing {
    if (input $"Type ($confirmation) to continue: ") != $confirmation {
      error make {msg: $"Installation cancelled: ($confirmation) was not confirmed."}
    }
  }
}

def missing-facter-report [target: record, directory: path] {
  # Local VM hardware must not become the production machine's hardware report.
  if $target.qemu != null or $target.sourceSopsFile == null {
    return null
  }
  let project_root = $env.PRJ_ROOT | path expand --strict
  let source = $target.sourceSopsFile | path expand
  let machine_directory = $source | path dirname
  let report = $machine_directory | path join "facter.json"
  if (($source | path basename) != "secrets.enc.json"
      or ($machine_directory | path dirname) != ($project_root | path join "nix/machine")
      or not ($machine_directory | path join "configuration.nix" | path exists)
      or ($report | path exists)) {
    return null
  }
  let project_local = try {
    $directory | path expand --strict | path relative-to $project_root | ignore
    true
  } catch { false }
  if $project_local { $report }
}

def --wrapped main [
  node: string
  --allow: string = "" # Comma-separated confirmations: WIPE_ALL_DISKS,WIPE_LINUX,WIPE_NIXOS
  --non-interactive(-n) # Fail instead of prompting for missing confirmations
  --host: string
  --user: string
  --port(-p): int
  --substitute-on-destination # Allow the target to download paths from its binary caches
  --no-substitute-on-destination # Copy paths directly from the local store
  --help(-h)
  ...nixos_anywhere_options: string
] {
  let allowed = $allow | split row "," | str trim | where {|value| $value != "" } | uniq
  let unknown = $allowed | where {|value| $value not-in [WIPE_ALL_DISKS WIPE_LINUX WIPE_NIXOS] }
  if not ($unknown | is-empty) {
    error make {msg: $"Unknown confirmations: ($unknown | str join ','). Use WIPE_ALL_DISKS, WIPE_LINUX or WIPE_NIXOS."}
  }
  if $substitute_on_destination and $no_substitute_on_destination {
    error make {msg: "Use only one of --substitute-on-destination and --no-substitute-on-destination."}
  }
  ulimit --core-size 0

  let options = installation-options $nixos_anywhere_options
  let target = resolve-target $node
  let skip_substitutes = $no_substitute_on_destination or ($target.fastConnection and not $substitute_on_destination)

  with-disko-files $target {|files|
    # The installer may have /etc/hostid symlinked into its read-only Nix store.
    let pre_format_files = $files.pre_format_files | each {|file|
      if $target.hostId? != null and $file.dst == "/etc/hostid" {
        $file | update dst "/run/idr-anywhere/hostid"
      } else {
        $file
      }
    }
    let identity = if $options.identity_file == null and ($env.SSH_PRIVATE_KEY? | default "") != "" {
      let path = $files.temporary_directory | path join "ssh_identity"
      $"($env.SSH_PRIVATE_KEY)\n" | save $path
      chmod 0600 $path
      ["-i" $path]
    } else {
      []
    }
    let arguments = ssh-arguments $target {
      host: $host, user: $user, port: $port, options: ($identity ++ $options.ssh)
    }
    let hostname = $arguments | last
    let status = installation-status $arguments $target.disks --env-password=$options.env_password
    print $"Will install ($node) on ($hostname), using best-effort formatting with a full-wipe fallback: ($target.disks | str join ', ')."
    let required = if ($status.used | is-empty) {
      [WIPE_ALL_DISKS]
    } else {
      print $"Disks currently in use by ($status.os): ($status.used | str join ', ')."
      [WIPE_ALL_DISKS (if $status.os == "nixos" { "WIPE_NIXOS" } else { "WIPE_LINUX" })]
    }
    confirm-installation $required $allowed $non_interactive

    let report = if not $options.generates_hardware and "--vm-test" not-in $options.anywhere {
      missing-facter-report $target $files.temporary_directory
    }
    let hardware_options = if $report != null {
      ["--generate-hardware-config" "nixos-facter" $report]
    } else { [] }
    let connection = installation-ssh-config $arguments $files.temporary_directory
    with-installation-flake $node $target $files.temporary_directory --live-project=($options.generates_hardware or $report != null) {|flake|
      with-env {TMPDIR: $files.temporary_directory, IDR_SSH_CONFIG: $connection.config} {
        # ssh-copy-id uses SSH_OPTS internally, with a different format.
        hide-env --ignore-errors SSH_OPTS
        (nixos-anywhere
          --flake $flake
          ...(if $skip_substitutes { ["--no-substitute-on-destination"] } else { [] })
          --extra-files $files.post_format_files_path
          ...($pre_format_files | each {|file| ["--disk-encryption-keys" $file.dst $file.src]} | flatten)
          --target-host $"($connection.user)@($hostname)"
          ...$identity
          ...$options.anywhere
          ...$hardware_options
          --ssh-port $connection.port)
      }
    }
  }
  remember-host-key $target (ssh-arguments $target {})
}

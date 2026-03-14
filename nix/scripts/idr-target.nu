const target_file = path self | path dirname | path join "idr-target.nix"

use idr-common.nu [host-socket-prefix]

export def target-arguments [node: string] {
  let project_root = $env.PRJ_ROOT | path expand
  [
    "--argstr" "projectRoot" $project_root
    "--argstr" "projectRef" $"git+file://($project_root | url encode)"
    "--argstr" "node" $node
  ]
}

export def resolve-target [node: string] {
  let result = (nix eval --impure --json --file $target_file target
    ...(target-arguments $node)
    | complete)
  if $result.exit_code != 0 {
    error make {msg: $"Could not resolve deploy node ($node): ($result.stderr | str trim)"}
  }
  $result.stdout | from json
}

export def ssh-arguments [target: record, overrides: record] {
  let options = $overrides.options? | default []
  let port = $overrides.port?
  let user = $overrides.user?
  let hostname = $overrides.host? | default $target.hostname
  let default_user = if $target.sshUser? != null { $target.sshUser } else { whoami | str trim }

  ($options
    ++ (if $port != null { ["-p" ($port | into string)] } else { [] })
    ++ (if $user != null { ["-l" $user] } else { [] })
    ++ $target.sshOpts
    ++ ["-l" $default_user $hostname])
}

export def remember-host-key [target: record, arguments: list<string>] {
  if $target.sshHostPublicKey? == null {
    return
  }

  let configured = ssh -G ...$arguments | complete
  if $configured.exit_code != 0 {
    error make {msg: $"Could not determine the SSH host identity: ($configured.stderr | str trim)"}
  }
  # OpenSSH supplies the canonical hostname, including compressed IPv6 addresses.
  let settings = $configured.stdout | lines
    | parse -r '^(?<name>hostname|port|hostkeyalias) (?<value>.*)$'
    | transpose --as-record --header-row
  let host = if $settings.hostkeyalias? != null {
    $settings.hostkeyalias
  } else if $settings.port == "22" {
    $settings.hostname
  } else {
    $"[($settings.hostname)]:($settings.port)"
  }
  let line = $"($host) ($target.sshHostPublicKey | str trim)"
  let known_hosts = $env.PRJ_DATA_DIR | path join $"(host-socket-prefix 'ssh').known_hosts"
  if ($known_hosts | path exists) and $line in (open --raw $known_hosts | lines) {
    return
  }
  mkdir $env.PRJ_DATA_DIR
  $"($line)\n" | save --append $known_hosts
}

const receiver_file = path self | path dirname | path join "idr-copy-extra-files.nix"

use idr-target.nu [resolve-target target-arguments ssh-arguments remember-host-key]

def copy-receiver [node: string, arguments: list<string>] {
  let built = (nix build --impure --no-link --print-out-paths --file $receiver_file
    ...(target-arguments $node)
    | complete)
  if $built.exit_code != 0 {
    error make {msg: $"Could not build the file receiver for ($node): ($built.stderr | str trim)"}
  }
  let receiver = $built.stdout | str trim
  let options = $arguments | drop | each { to nuon } | str join " "
  with-env {SSH_OPTS: $"($env.SSH_OPTS? | default '') ($options)"} {
    let copied = nix copy --to $"ssh://($arguments | last)" $receiver | complete
    if $copied.exit_code != 0 {
      error make {msg: $"Could not copy the file receiver to ($arguments | last): ($copied.stderr | str trim)"}
    }
  }
  $receiver | path join "bin/idr-copy-extra-files-receiver"
}

def shell-quote [value: string] {
  $"'($value | str replace --all "'" "'\\''")'"
}

def --wrapped main [
  node: string
  --host: string
  --user: string
  --port: int
  --help(-h)
  ...ssh_options: string
] {
  ulimit --core-size 0
  let target = resolve-target $node
  let files = $target.postFormatFiles | values
  if ($files | is-empty) {
    return
  }
  let arguments = ssh-arguments $target {
    host: $host, user: $user, port: $port, options: (["-T"] ++ $ssh_options)
  }
  let receiver = copy-receiver $node $arguments

  for file in $files {
    let extract_args = if $file.key? == null {
      []
    } else {
      ["--extract" ([$file.key] | to json -r)]
    }
    let decrypted = sops decrypt ...$extract_args $file.sopsFile | complete
    if $decrypted.exit_code != 0 {
      error make {msg: $"Could not decrypt ($file.sopsFile): ($decrypted.stderr | str trim)"}
    }

    let public_key = match $file.key {
      "ssh_host_ed25519_key" => $target.sshHostPublicKey
      "initrd_ssh_host_ed25519_key" => $target.initrdHostPublicKey
      _ => null
    }
    if $public_key != null {
      let derived = $decrypted.stdout | ssh-keygen -y -P "" -f /dev/stdin | complete
      let actual = $derived.stdout | str trim | split row " " | first 2 | str join " "
      let expected = $public_key | split row " " | first 2 | str join " "
      if $derived.exit_code != 0 or $actual != $expected {
        error make {msg: $"SSH host key for ($file.path) is invalid or does not match its declared public key."}
      }
    }

    let expected_hash = $decrypted.stdout | hash sha256
    let check_command = [$receiver "check" $file.path $expected_hash]
      | each {|argument| shell-quote $argument }
      | str join " "
    let checked = ssh ...$arguments $check_command | complete
    if $checked.exit_code != 0 {
      error make {msg: $"Could not check ($file.path): ($checked.stderr | str trim)"}
    }
    if ($checked.stdout | str trim) == "unchanged" {
      print $"Unchanged: ($arguments | last):($file.path)"
      continue
    }

    let command = [$receiver "install" $file.path $expected_hash]
      | each {|argument| shell-quote $argument }
      | str join " "
    let copied = $decrypted.stdout | ssh ...$arguments $command | complete
    if $copied.exit_code != 0 {
      error make {msg: $"Could not copy ($file.path): ($copied.stderr | str trim)"}
    }
    print $"Copied ($file.sopsFile) to ($arguments | last):($file.path)"
  }
  remember-host-key $target $arguments
}

use idr-target.nu [resolve-target ssh-arguments]

def remaining-seconds [deadline: datetime, message: string] {
  let seconds = ($deadline - (date now)) / 1sec | math ceil
  if $seconds <= 0 {
    error make {msg: $message}
  }
  $seconds | into int
}

export def unlock [
  arguments: list<string>
  disk_key: record
  host_keys: list<string>
  --agent: record
  --timeout: duration = 5min
  --ssh-options: list<string> = []
] {
  ulimit --core-size 0
  $env.LC_ALL = "C"
  let destination = $arguments | last
  let deadline = (date now) + $timeout
  let timeout_message = $"Timed out waiting for disk unlock over SSH at ($destination)."
  let options = $ssh_options ++ [
    "-T"
    "-o" "ControlMaster=no"
    "-o" "ControlPath=none"
    "-o" "UserKnownHostsFile=/dev/null"
    "-o" "GlobalKnownHostsFile=/dev/null"
    "-o" $'KnownHostsCommand="(which printenv | get 0.path)" IDR_UNLOCK_KNOWN_HOSTS'
    "-o" "StrictHostKeyChecking=yes"
    "-o" "BatchMode=yes"
    "-o" "ConnectTimeout=2"
    "-o" "ServerAliveInterval=5"
    "-o" "ServerAliveCountMax=1"
    "-o" "LogLevel=ERROR"
  ] ++ $arguments

  $env.IDR_UNLOCK_KNOWN_HOSTS = $host_keys | each {|key| $"* ($key)" } | str join "\n"
  let remaining = [60 (remaining-seconds $deadline $timeout_message)] | math min
  let decrypted = timeout --kill-after=5s $"($remaining)s" sops decrypt --extract ([$disk_key.key] | to json -r) $disk_key.sopsFile | complete
  if $decrypted.exit_code != 0 {
    error make {msg: $"Could not decrypt the disk key: ($decrypted.stderr | str trim)"}
  }

  if $agent != null {
    $env.SSH_AUTH_SOCK = $agent.socket
  }
  mut last_error = ""
  loop {
    let remaining = remaining-seconds $deadline ($"($timeout_message)\n($last_error)" | str trim)
    let result = generate {|password| {out: $password, next: $password} } $decrypted.stdout
      | to text
      | timeout --kill-after=5s $"($remaining)s" ssh ...$options
      | complete
    if $result.exit_code == 0 {
      print --stderr $"Sent disk key to ($destination)."
      break
    }
    let stderr = $result.stderr | str trim
    if $stderr != "" {
      $last_error = $stderr
    }
    remaining-seconds $deadline ($"($timeout_message)\n($last_error)" | str trim) | ignore
    if $result.exit_code != 255 or $result.stderr !~ '(ssh: connect to host .* port [0-9]+: (Connection refused|Network is unreachable|No route to host|Connection timed out|Operation timed out)|Connection timed out during banner exchange)' {
      error make {msg: $"Disk unlock over SSH failed with exit code ($result.exit_code): ($stderr)"}
    }
    sleep 1sec
  }
}

def --wrapped main [
  node: string
  --host: string
  --user: string = "root"
  --port: int
  --timeout: duration = 5min
  --host-key-fingerprint: string # Trust this recorded initrd key for a rollback (SHA256:...).
  --help(-h)
  ...ssh_options: string
] {
  let target = resolve-target $node
  if $target.diskKey == null {
    error make {msg: $"No disk key is configured for ($target.machine)."}
  }
  if $target.initrdHostPublicKey == null {
    error make {msg: $"No initrd SSH host key is configured for ($target.machine)."}
  }
  let host_keys = if $host_key_fingerprint == null {
    [$target.initrdHostPublicKey]
  } else {
    $target.initrdHostPublicKeys | where {|key|
      let fingerprint = $key | split row " " | get 1
        | decode base64 | hash sha256 --binary | encode base64 | str trim --right --char "="
      $"SHA256:($fingerprint)" == $host_key_fingerprint
    }
  }
  if ($host_keys | is-empty) {
    error make {msg: $"No recorded initrd SSH host key matches ($host_key_fingerprint)."}
  }
  let target = $target | update sshOpts ($target.sshOpts ++ ["-p" ($target.initrdPort | into string)])
  let arguments = ssh-arguments $target {
    host: $host, user: $user, port: $port
  }
  unlock $arguments $target.diskKey $host_keys --timeout $timeout --ssh-options $ssh_options
}

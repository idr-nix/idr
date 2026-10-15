# The wrapper owns the credential lock and cleans the private SSH session.
def --wrapped checked [...args: string] {
  let result = run-external ...$args | complete
  if $result.exit_code != 0 {
    error make {msg: $"($args | first) failed: ($result.stderr | str trim)"}
  }
  $result.stdout | str trim
}

def write-config [config: record, work: path, name: string, pins: string, identities: list<string>] {
  let settings = {
    HostName: $config.target, User: root, Port: 22,
    ProxyCommand: $config.proxy, ProxyUseFdpass: yes,
    BatchMode: yes, IdentitiesOnly: yes, IdentityAgent: none,
    HostKeyAlgorithms: ssh-ed25519, StrictHostKeyChecking: yes,
    UserKnownHostsFile: $pins, GlobalKnownHostsFile: /dev/null,
    UpdateHostKeys: no, CheckHostIP: no, ConnectTimeout: 3,
    ConnectionAttempts: 1, ServerAliveInterval: 5, ServerAliveCountMax: 3,
    ControlMaster: auto, ControlPath: $"($work)/c", ControlPersist: no
  }
  let lines = $settings | transpose key value | each {|entry| $"  ($entry.key) ($entry.value)" }
  let keys = $identities | where {|identity| $identity | path exists } | each {|identity| $"  IdentityFile ($identity)" }
  ([$"Host ($config.target)"] ++ $lines ++ $keys | str join "\n") + "\n" | save --force ($work | path join $name)
}

def connect [config: record, work: path, action: string] {
  if ($config.identity_path | path exists) {
    checked install -m 0600 $config.identity_path $"($work)/identity" | ignore
    checked ssh-keygen -y -P '' -f $"($work)/identity" | ignore
  } else if $action == deploy {
    error make {msg: $"The configured host SSH identity is missing: ($config.identity_path)"}
  }
  let pins = [$config.desired_pin $"($config.state_dir)/current/guest-host-key" $"($config.state_dir)/previous/guest-host-key"]
  $pins | where {|pin| $pin | path exists } | each {|pin| $"($config.target) (open --raw $pin | str trim)\n" } | str join | save --force $"($work)/known_hosts"
  $"($config.target) (open --raw $config.desired_pin | str trim)\n" | save --force $"($work)/desired_known_hosts"
  write-config $config $work ssh.conf $"($work)/known_hosts" [$"($work)/identity" $"($config.state_dir)/current/identity" $"($config.state_dir)/previous/identity"]
  write-config $config $work fresh.conf $"($work)/desired_known_hosts" [$"($work)/identity"]
  let deadline = (date now) + 60sec
  loop {
    let result = ssh -F $"($work)/ssh.conf" -MNf $config.target | complete
    if $result.exit_code == 0 { break }
    if (date now) >= $deadline {
      error make {msg: $"The guest deployment socket did not become ready within 60 seconds: ($result.stderr)"}
    }
    sleep 1sec
  }
  let identity = checked ssh -F $"($work)/ssh.conf" $config.target 'cat /run/current-system/etc/idr-microvm-identity'
  if $identity != $config.guest_identity {
    error make {msg: "Refusing to manage a guest with a different IDR machine identity."}
  }
}

def verify-credentials [config: record, work: path] {
  let deadline = (date now) + 20sec
  mut last_error = ''
  loop {
    let remaining = ($deadline - (date now)) / 1sec
    if $remaining <= 0 {
      error make {msg: $"The guest's new deployment credentials could not be verified within 20 seconds: ($last_error)"}
    }
    let result = timeout --foreground ($remaining | into string) ssh -F $"($work)/fresh.conf" -o ControlPath=none $config.target true | complete
    if $result.exit_code == 0 { return }
    $last_error = $result.stderr
    sleep 1sec
  }
}

def activate [config: record, work: path] {
  let ssh_config = $"($work)/ssh.conf"
  let remote_base = "/run/idr-microvm-deploy"
  let remote_temp = $"($remote_base)/($work | path basename)"
  checked ssh -F $ssh_config $config.target $"install -d -m 0700 '($remote_base)' '($remote_temp)'" | ignore
  # Keep deploy-rs' canary protocol: only fresh credentials may confirm a switch.
  touch $"($work)/activation-started"
  let command = $"flock --exclusive --nonblock '($remote_base)/deployment.lock' '($config.activate_guest)' '($remote_temp)' >'($remote_temp)/activation.log' 2>&1; result=$?; cat '($remote_temp)/activation.log'; exit $result"
  let activation_job = job spawn {
    let result = ssh -n -F $ssh_config $config.target $command | complete
    touch $"($work)/activation-finished"
    $result | job send 0 --tag 1
  }
  let waiter = job spawn {
    ssh -n -F $ssh_config $config.target $"'($config.activation)/activate-rs' wait '($config.activation)' --activation-timeout 180 --temp-path '($remote_temp)'" | complete | job send 0 --tag 2
  }
  try {
    loop {
      let result = try { job recv --tag 2 --timeout 100ms } catch { null }
      if $result != null {
        if $result.exit_code != 0 {
          error make {msg: $"Guest activation failed; deploy-rs is responsible for rollback. ($result.stderr)"}
        }
        break
      }
      if ($"($work)/activation-finished" | path exists) {
        error make {msg: "Guest activation ended before the confirmation waiter succeeded."}
      }
    }
    verify-credentials $config $work
    let hash = $config.activation | path basename | split row '-' | first
    checked ssh -F $ssh_config $config.target $"rm '($remote_temp)/deploy-rs-canary-($hash)'" | ignore
  } finally {|error|
    # Leave the canary intact on failure; keep the lock during magic rollback.
    try { job kill $waiter } catch { null }
    let result = try { job recv --tag 1 --timeout 45sec } catch { null }
    try { job kill $activation_job } catch { null }
    if $result != null {
      print --no-newline $result.stdout
      print --stderr --no-newline $result.stderr
    }
    if $error != null { error make $error }
    if $result == null or $result.exit_code != 0 {
      error make {msg: "Guest activation did not finish successfully."}
    }
  }
}

def deploy [config: record, work: path] {
  let ssh_config = $"($work)/ssh.conf"
  $env.NIX_SSHOPTS = $"-F ($ssh_config)"
  $env.SSH_OPTS = $env.NIX_SSHOPTS
  do --capture-errors {
    nix --extra-experimental-features nix-command copy --no-check-sigs --to $"ssh://root@($config.target)" $config.activation $config.activate_guest $config.receiver
    $env.SOPS_AGE_KEY_CMD = $"($config.ssh_to_age) -private-key -i ($work)/identity"
    run-external $config.stage_files $config.files $ssh_config $config.target $work
  }
  let systems = checked ssh -F $ssh_config $config.target 'readlink -f /nix/var/nix/profiles/system && readlink -f /run/current-system'
  if $systems == $"($config.activation)\n($config.guest_toplevel)" {
    print "Guest already runs the requested generation; skipping activation."
    verify-credentials $config $work
  } else {
    activate $config $work
  }
  # Publish credentials only after confirmation, retaining one rollback pair.
  let current = $"($config.state_dir)/current"
  let same_identity = (cmp -s $"($work)/identity" $"($current)/identity" | complete).exit_code == 0
  let same_pin = (cmp -s $config.desired_pin $"($current)/guest-host-key" | complete).exit_code == 0
  if not $same_identity or not $same_pin {
    checked install -d -m 0700 $"($work)/credentials" | ignore
    checked install -m 0600 $"($work)/identity" $"($work)/credentials/identity" | ignore
    checked install -m 0600 $config.desired_pin $"($work)/credentials/guest-host-key" | ignore
    rm --recursive --force $"($config.state_dir)/previous"
    if ($current | path exists) { mv $current $"($config.state_dir)/previous" }
    mv $"($work)/credentials" $current
  }
  print "Guest deployment confirmed."
}

def main [manifest: path, work: path, action: string] {
  ulimit --core-size 0
  let config = open --raw $manifest | from json
  connect $config $work $action
  if $action == ssh {
    # The authenticated master now uses its private credential snapshot.
    checked flock --unlock 9 | ignore
    return
  }
  deploy $config $work
}

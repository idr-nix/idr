const script_path = path self

use idr-common.nu [host-data-dir host-socket-prefix save-atomic]

def main [] {}

def "main add" [machine: string, machine_id: string] {
  ulimit --core-size 0
  let prefix = host-socket-prefix "ssh"
  $env.IDR_SSH_AUTH_SOCK = $env.PRJ_DATA_DIR | path join $"($prefix)-($machine_id).sock" | path expand
  exec flock --close $"($env.IDR_SSH_AUTH_SOCK).lock" $nu.current-exe -n --no-std-lib --no-history $script_path load $machine
}

def "main load" [machine: string] {
  let secret = key-directory $machine | path join "secrets.enc.json"
  # SOPS uses the caller's agent; only ssh-add uses the temporary one.
  let decrypted = sops decrypt --extract '["ssh_private_key"]' $secret | complete
  if $decrypted.exit_code != 0 {
    error make {msg: $"Could not decrypt the temporary SSH key for ($machine): ($decrypted.stderr | str trim)"}
  }

  with-env {SSH_AUTH_SOCK: $env.IDR_SSH_AUTH_SOCK} {
    if (ssh-add -l | complete | get exit_code) == 2 {
      rm --force $env.SSH_AUTH_SOCK
      let started = ^$nu.current-exe -n --no-std-lib --no-history $script_path agent | complete
      if $started.exit_code != 0 {
        error make {msg: "Could not start the temporary SSH agent."}
      }
    }
    $decrypted.stdout | ssh-add -q -t 30 -
  }
}

def "main agent" [] {
  # Leave the watchdog running after its readiness message reaches the caller.
  "" | ssh-agent -a $env.IDR_SSH_AUTH_SOCK $nu.current-exe -n --no-std-lib --no-history $script_path watch e> /dev/null
    | lines
    | each { exit 0 }
    | ignore
  exit 1
}

def "main watch" [] {
  print ready
  loop {
    sleep 1sec
    let check = flock --close $"($env.SSH_AUTH_SOCK).lock" $nu.current-exe -n --no-std-lib --no-history $script_path expire | complete
    if $check.exit_code != 1 {
      break
    }
  }
}

def "main expire" [] {
  let status = ssh-add -l | complete
  if $status.exit_code == 0 {
    # Ask the watchdog to retry while the agent still has keys.
    exit 1
  }
  if $status.exit_code == 1 and (ssh-agent -k | complete | get exit_code) == 0 {
    # Keep the lock until this agent can no longer unlink a replacement's socket.
    let pid = $env.SSH_AGENT_PID | into int
    while (ps | any {|process| $process.pid == $pid and $process.status != "Zombie"}) {
      sleep 10ms
    }
  }
}

export def key-directory [machine: string] {
  host-data-dir | path join $machine "qemu" "ssh" | path expand
}

export def prepare-agent [agent: record, filename: string, directory: path] {
  let private_key = prepare-key $filename $directory
  with-env {SSH_AUTH_SOCK: $agent.socket} {
    let loaded = $private_key
      | timeout --kill-after=5s 60s ssh-add -
      | complete
    if $loaded.exit_code != 0 {
      error make {msg: "Could not load the temporary SSH key."}
    }
    $agent | insert public_key (ssh-add -L | str trim)
  }
}

export def stop-agent [agent: record] {
  try { kill $agent.pid }
}

def prepare-key [filename: string, directory: path] {
  let config_path = $directory | path join ".sops.yaml"
  let secret_path = $directory | path join "secrets.enc.json"
  let policy = open $env.IDR_QEMU_SOPS_CONFIG
  let rule = $policy.creation_rules
    | where {|rule| $filename =~ ($rule.path_regex? | default "")}
    | first
    # The dedicated key file must encrypt every value, even with selective project rules.
    | reject -o encrypted_regex encrypted_suffix unencrypted_regex unencrypted_suffix encrypted_comment_regex unencrypted_comment_regex
    | upsert path_regex '^secrets\.enc\.json$'

  mkdir $directory
  chmod 0700 $directory
  $policy | update creation_rules [$rule] | to yaml | save-atomic $config_path

  cd $directory
  $env.SOPS_CONFIG = ".sops.yaml"
  let reuse = if ($secret_path | path exists) {
    let existing = open $secret_path
    # EOF declines recipient changes; unchanged files exit successfully without decryption.
    let checked = "" | sops updatekeys secrets.enc.json | complete
    # updatekeys does not compare the configured Shamir threshold.
    let group_count = $rule.key_groups? | default [] | length
    let threshold = $rule.shamir_threshold? | default 0
    let threshold = if $threshold == 0 { $group_count } else { $threshold }
    (
      ($existing.ssh_private_key | str starts-with "ENC[AES256_GCM,")
      and $checked.exit_code == 0
      and ($group_count <= 1 or $existing.sops.shamir_threshold? == $threshold)
    )
  } else {
    false
  }
  if $reuse {
    let decrypted = timeout --kill-after=5s 60s sops decrypt --extract '["ssh_private_key"]' secrets.enc.json | complete
    if $decrypted.exit_code != 0 {
      error make {msg: "Could not decrypt the temporary SSH key with SOPS."}
    }
    return $decrypted.stdout
  }

  let generated = timeout --kill-after=5s 60s openssl genpkey -algorithm ED25519 | complete
  if $generated.exit_code != 0 {
    error make {msg: "Could not generate the temporary SSH key."}
  }
  let encrypted = {ssh_private_key: $generated.stdout}
    | to json
    | sops encrypt --filename-override secrets.enc.json
    | complete
  if $encrypted.exit_code != 0 {
    error make {msg: $"Could not encrypt the temporary SSH key: ($encrypted.stderr | str trim)"}
  }
  if not ($encrypted.stdout | from json | get ssh_private_key | str starts-with "ENC[AES256_GCM,") {
    error make {msg: "SOPS did not encrypt the temporary SSH key."}
  }
  $encrypted.stdout | save-atomic $secret_path
  chmod 0600 $secret_path
  $generated.stdout
}

use std/assert

def decrypt [file: path] {
  sops decrypt $file | from json
}

def set-field [file: path, field: string, value: any] {
  sops --in-place --set $"[($field | to json --raw)] ($value | to json --raw)" $file
}

def timestamp [secrets: record, field: string] {
  $secrets | get $"($field)@_unencrypted"
    | parse 'interval={interval} modified_ts={timestamp}' | get 0.timestamp
}

def public-key [private: string] {
  $private | ssh-keygen -y -P "" -f /dev/stdin | split row " " | first 2 | str join " " | str trim
}

def check-keys [secrets: record, disk: record] {
  for field in [ssh_host_ed25519_key initrd_ssh_host_ed25519_key] {
    assert equal (public-key ($secrets | get $field)) ($secrets | get $"($field)_pub_unencrypted")
  }
  assert equal ($disk.disk_key | hash sha256) $disk.disk_key_hash_unencrypted
  assert not ("disk_key" in $secrets)
  assert ($disk | columns | all {|field| $field | str starts-with "disk_key" })
}

def check-unlock-access [disk_file: path, other_files: list<string>] {
  let recipient = open $env.IDR_TEAM_JSON_FILE | get unlock-server-test.agePublicKey
  assert ($recipient in (open $disk_file | get sops.age.recipient))
  for file in $other_files {
    assert not ($recipient in (open $file | get sops.age.recipient))
  }
  let identity = ssh-to-age -i ($env.PRJ_DATA_DIR | path join "unlock-server") -private-key
  with-env {
    SOPS_AGE_KEY: $identity, SOPS_AGE_KEY_FILE: "/dev/null"
    SOPS_AGE_SSH_PRIVATE_KEY_FILE: "/dev/null"
  } {
    hide-env -i SOPS_AGE_KEY_CMD SOPS_AGE_SSH_PRIVATE_KEY_CMD
    assert (sops decrypt $disk_file | from json | get disk_key | is-not-empty)
    for file in $other_files {
      assert not equal (sops decrypt $file | complete | get exit_code) 0 "Unlock servers must not decrypt machine or role secrets"
    }
  }
}

def main [] {
  assert equal $env.PRJ_ROOT "/tmp/project"
  assert equal $env.PRJ_DATA_DIR "/tmp/project/.data"
  let host = open --raw /etc/machine-id | str trim
  assert equal $env.PRE_COMMIT_HOME ($env.PRJ_DATA_DIR | path join $host "pre-commit")
  assert equal ("generated/link.txt" | path type) "symlink"
  assert equal ("generated/copied.txt" | path type) "file"
  assert equal (open --raw generated/copied.txt) "generated\n"
  assert equal (open --raw ($env.PRJ_DATA_DIR | path join "generated-hooks")) "x"
  let file = "nix/machine/test-machine/secrets.enc.json"
  let disk_file = "nix/machine/test-machine/disk-key.enc.json"
  let bootstrap = $env.PRJ_DATA_DIR | path join "machine-host-key/test-machine"
  assert not ($bootstrap | path exists) "Operator access must retire the plaintext bootstrap identity"
  assert not ($"($bootstrap).pub" | path exists)
  let initial = decrypt $file
  let initial_disk = decrypt $disk_file
  let operator = open $env.IDR_TEAM_JSON_FILE | get operator.agePublicKey
  let recipients = open $file | get sops.age.recipient
  assert ($operator in $recipients)
  assert ($initial.ssh_host_ed25519_key_age_pub_unencrypted in $recipients)

  let role = "nix/role/test/secrets.enc.json"
  let yaml = "nix/role/test/multi line.enc.yaml"
  assert ("token@_unencrypted" in (open $role))
  assert ("text@_unencrypted" in (open $yaml))
  assert equal (sops decrypt $yaml | decode utf-8 | from yaml | get text) "first line\nsecond line\n"
  let role_before = open --raw $role
  check-unlock-access $disk_file [$file $role $yaml]

  let before = open --raw $file
  let disk_before = open --raw $disk_file
  idr-rotate-keys test-machine
  assert equal (open --raw $file) $before "Fresh keys must not rotate without --force"
  assert equal (open --raw $disk_file) $disk_before

  set-field $file "root_password@_unencrypted" "interval=1day modified_ts=0"
  set-field $disk_file "disk_key@_unencrypted" "interval=1day modified_ts=0"
  idr-rotate-keys test-machine
  let expired = decrypt $file
  let expired_disk = decrypt $disk_file
  assert ($expired.ssh_host_ed25519_key == $initial.ssh_host_ed25519_key)
  assert ($expired.initrd_ssh_host_ed25519_key == $initial.initrd_ssh_host_ed25519_key)
  assert ($expired_disk.disk_key != $initial_disk.disk_key)
  assert ($expired.root_password != $initial.root_password)
  assert equal (timestamp $expired_disk disk_key) (timestamp $expired root_password)
  assert equal (timestamp $expired_disk disk_key) (timestamp $expired_disk disk_key_hash_unencrypted)
  assert equal (timestamp $expired root_password) (timestamp $expired root_password_hash_unencrypted)

  # A host-only rotation changes the disk file's recipients, preserving its key and age.
  let disk_before_host_rotation = open $disk_file
  set-field $file "ssh_host_ed25519_key@_unencrypted" "interval=1day modified_ts=0"
  idr-rotate-keys test-machine
  let host_rotated = decrypt $file
  assert ($host_rotated.ssh_host_ed25519_key != $expired.ssh_host_ed25519_key)
  assert equal (decrypt $disk_file) $expired_disk
  assert not equal (open $disk_file | get disk_key) $disk_before_host_rotation.disk_key "Recipient changes must rotate the disk file's data key"
  assert ($host_rotated.ssh_host_ed25519_key_age_pub_unencrypted in (open $disk_file | get sops.age.recipient))
  assert not ($expired.ssh_host_ed25519_key_age_pub_unencrypted in (open $disk_file | get sops.age.recipient))
  check-unlock-access $disk_file [$file $role $yaml]

  idr-rotate-keys test-machine --force
  let rotated = decrypt $file
  let rotated_disk = decrypt $disk_file
  check-keys $rotated $rotated_disk
  let fields = [ssh_host_ed25519_key initrd_ssh_host_ed25519_key root_password]
  for field in $fields {
    assert (($rotated | get $field) != ($expired | get $field)) $"--force must rotate ($field)"
    assert (open $file | get $field | str starts-with "ENC[AES256_GCM,")
  }
  assert ($rotated_disk.disk_key != $expired_disk.disk_key) "--force must rotate the disk key"
  assert (open $disk_file | get disk_key | str starts-with "ENC[AES256_GCM,")
  assert equal ($fields | each {|field| timestamp $rotated $field } | append (timestamp $rotated_disk disk_key) | uniq | length) 1
  assert ((public-key $initial.initrd_ssh_host_ed25519_key) in $rotated.initrd_ssh_host_ed25519_key_pub_history_unencrypted)

  for secret_file in [$file $disk_file $role $yaml] {
    let recipients = open $secret_file | get sops.age.recipient
    assert ($rotated.ssh_host_ed25519_key_age_pub_unencrypted in $recipients)
    assert not ($initial.ssh_host_ed25519_key_age_pub_unencrypted in $recipients)
    assert ($operator in $recipients)
  }
  assert equal (decrypt $role | get token) "role data survives recipient rotation"
  assert not equal (open $role | get token) ($role_before | from json | get token) "Role data keys must rotate with their recipients"
  check-unlock-access $disk_file [$file $role $yaml]

  let old_age_key = $initial.ssh_host_ed25519_key | ssh-to-age -private-key
  with-env {
    SOPS_AGE_KEY: $old_age_key, SOPS_AGE_KEY_FILE: "/dev/null"
    SOPS_AGE_SSH_PRIVATE_KEY_FILE: "/dev/null"
  } {
    hide-env -i SOPS_AGE_KEY_CMD SOPS_AGE_SSH_PRIVATE_KEY_CMD
    for secret_file in [$file $disk_file $role] {
      let result = sops decrypt $secret_file | complete
      assert not equal $result.exit_code 0 "The retired host identity must no longer decrypt current secrets"
    }
  }

  let unchanged = open --raw $file
  let disk_unchanged = open --raw $disk_file
  idr-rotate-keys test-machine
  assert equal (open --raw $file) $unchanged
  assert equal (open --raw $disk_file) $disk_unchanged
  assert (glob $"($env.PRJ_DATA_DIR)/idr-rotate-keys-*" | is-empty) "Rotation must remove its staging directory"

  # A policy that would expose private fields must fail before replacing any file.
  let module = "nix/testing/flake-module.nix"
  let configuration = open --raw $module
  'top: { ... }: {
    idr.sops.creation_rules = [{
      priority = 1000;
      rule = {
        path_regex = "^nix/machine/test-machine/disk-key\\.enc\\.json$";
        age = ["@OPERATOR@"];
        unencrypted_regex = ".*";
      };
    }];
    flake.modules.nixos.test-machine = { config, lib, ... }: {
      config = lib.mkIf (config.networking.hostName == "test-machine") {
        idr.roles."test-${(lib.importJSON ../role/test/meta.json).id}".enable = true;
      };
    };
  }' | str replace @OPERATOR@ $operator | save --force $module
  let role_before_failure = open --raw $role
  let failed = idr-rotate-keys test-machine --force | complete
  $configuration | save --force $module
  assert not equal $failed.exit_code 0
  assert ($failed.stderr | str contains "must encrypt")
  assert equal (open --raw $file) $unchanged
  assert equal (open --raw $disk_file) $disk_unchanged
  assert equal (open --raw $role) $role_before_failure
  assert (glob $"($env.PRJ_DATA_DIR)/idr-rotate-keys-*" | is-empty)

  # The next real shell startup must repair missing or edited generated files.
  "edited" | save --force generated/copied.txt
  rm generated/link.txt
}

use idr-common.nu [save-atomic]
use idr-target.nu [resolve-target]

def checked [message: string] {
  let result = $in
  if $result.exit_code != 0 {
    error make {msg: $"($message): ($result.stderr | str trim)"}
  }
  $result.stdout
}

def ssh-key [] {
  idr-generate-ssh-key | complete | checked "Could not generate an SSH key" | from json
}

def rotation-metadata [secrets: record, field: string] {
  let annotation = $secrets | get -o $"($field)@_unencrypted"
  if $annotation == null {
    return null
  }
  $annotation | parse 'interval={interval} modified_ts={modified_ts}' | first
}

def expired [secrets: record, field: string, timestamp: int] {
  let metadata = rotation-metadata $secrets $field
  $metadata != null and (($timestamp - ($metadata.modified_ts | into int)) * 1sec >= ($metadata.interval | into duration))
}

def replace-age [group: record, old: string, new: string] {
  if "age" not-in $group {
    return $group
  }
  let age = if ($group.age | describe) == "string" {
    $group.age | str replace --all $old $new
  } else {
    $group.age | each {|recipient| if $recipient == $old { $new } else { $recipient } }
  }
  $group | update age $age
}

def replace-rule-age [rule: record, old: string, new: string] {
  let rule = replace-age $rule $old $new
  if "key_groups" in $rule {
    $rule | update key_groups ($rule.key_groups | each {|group| replace-age $group $old $new })
  } else {
    $rule
  }
}

def selected-rule [policy: record, filename: string] {
  $policy.creation_rules
    | where {|rule| $filename =~ ($rule.path_regex? | default "") }
    | first
}

def file-policy [policy: record, rule: record, directory: path] {
  mkdir $directory
  let config = $directory | path join ".sops.yaml"
  $policy
    | update creation_rules [($rule | upsert path_regex '^secrets\.enc\.(json|yaml|bin)$')]
    | to yaml
    | save $config
  $config
}

def writable-file [path: path, root: path] {
  let file = $path | path expand
  $file | path relative-to $root | ignore
  let info = ls --directory --long $file | first
  if $info.type != "file" or $info.readonly {
    error make {msg: $"($file) must be a writable repository file."}
  }
  $file
}

def main [node: string, --force] {
  ulimit --core-size 0
  let timestamp = date now | format date "%s" | into int
  let target = resolve-target $node
  if $target.sourceSopsFile? == null {
    error make {msg: "The machine's secrets file must belong to the current project."}
  }
  if $target.diskKey != null and $target.sourceDiskKeyFile == null {
    error make {msg: "The machine's disk-key file must belong to the current project."}
  }
  let root = $env.PRJ_ROOT | path expand
  cd $root
  let disk_field = if $target.diskKey == null { null } else { $target.diskKey.key }
  let managed_files = [{path: $target.sourceSopsFile, fields: [ssh_host_ed25519_key initrd_ssh_host_ed25519_key root_password]}]
    | append (if $disk_field == null { [] } else { [{path: $target.sourceDiskKeyFile, fields: [$disk_field]}] })
    | group-by path | transpose path files
    | each {|file|
      let path = writable-file $file.path $root
      let original = open --raw $path
      let metadata = $original | from json
      let private_fields = $file.files.fields | flatten
      let fields = $private_fields | where {|field| $field in $metadata and ($force or (expired $metadata $field $timestamp)) }
      {path: $path, original: $original, fields: $fields, privateFields: $private_fields}
    } | where {|file| $file.fields | is-not-empty }
  if ($managed_files | is-empty) {
    print "No managed keys are due for rotation."
    return
  }
  mut updates = []
  mut old_age = ""
  mut new_age = ""
  let default_interval = $env.IDR_ROTATION_DEFAULT_INTERVAL? | default "90day"
  for file in $managed_files {
    let secrets = sops decrypt $file.path | complete | checked $"Could not decrypt ($file.path)" | from json
    mut changes = {}
    if "ssh_host_ed25519_key" in $file.fields {
      let key = ssh-key
      $old_age = if "ssh_host_ed25519_key_age_pub_unencrypted" in $secrets {
        $secrets.ssh_host_ed25519_key_age_pub_unencrypted
      } else {
        $secrets.ssh_host_ed25519_key
          | ssh-keygen -y -f /dev/stdin
          | complete | checked "Could not derive the old SSH public key"
          | ssh-to-age | complete | checked "Could not derive the old age recipient" | str trim
      }
      $new_age = $key.public | ssh-to-age | complete | checked "Could not derive the new age recipient" | str trim
      $changes = $changes | merge {
        ssh_host_ed25519_key: $key.private
        ssh_host_ed25519_key_pub_unencrypted: $key.public
        ssh_host_ed25519_key_age_pub_unencrypted: $new_age
      }
    }
    if "initrd_ssh_host_ed25519_key" in $file.fields {
      let key = ssh-key
      # Older boot generations keep their initrd host keys.
      let public_key = $secrets.initrd_ssh_host_ed25519_key
        | ssh-keygen -y -P "" -f /dev/stdin
        | complete | checked "Could not derive the previous initrd SSH public key" | str trim
      let history = $secrets.initrd_ssh_host_ed25519_key_pub_history_unencrypted? | default []
        | append $public_key | each {|key| $key | split row " " | first 2 | str join " " } | uniq
      $changes = $changes | merge {
        initrd_ssh_host_ed25519_key: $key.private
        initrd_ssh_host_ed25519_key_pub_unencrypted: $key.public
        initrd_ssh_host_ed25519_key_pub_history_unencrypted: $history
      }
    }
    if "root_password" in $file.fields {
      let password = random chars --length 64
      let hash = $password | mkpasswd --stdin | complete | checked "Could not hash the root password" | str trim
      $changes = $changes | merge {root_password: $password, root_password_hash_unencrypted: $hash}
    }
    if $disk_field in $file.fields {
      let disk_key = random chars --length 64
      $changes = $changes | merge {
        $disk_field: $disk_key
        $"($disk_field)_hash_unencrypted": ($disk_key | hash sha256)
      }
    }
    for field in ($changes | columns) {
      let annotation = $"($field)@_unencrypted"
      let metadata = rotation-metadata $secrets $field
      let interval = $metadata.interval? | default $default_interval
      $changes = $changes | upsert $annotation $"interval=($interval) modified_ts=($timestamp)"
    }
    $updates = $updates | append ($file | merge {updated: ($secrets | merge $changes), changes: $changes})
  }
  let old_age = $old_age
  let new_age = $new_age

  let policy_path = nix build --no-link --print-out-paths $"($root)#idr-sops-config" | complete | checked "Could not build the SOPS policy" | str trim
  let policy = open $policy_path
  let new_policy = if $old_age != "" {
    $policy | update creation_rules ($policy.creation_rules | each {|rule| replace-rule-age $rule $old_age $new_age })
  } else {
    $policy
  }

  # Encryption recipients come from the project policy; decryption credentials stay available.
  hide-env -i SOPS_AGE_RECIPIENTS SOPS_KMS_ARN SOPS_GCP_KMS_IDS SOPS_HUAWEICLOUD_KMS_IDS SOPS_AZURE_KEYVAULT_URLS SOPS_VAULT_URIS SOPS_PGP_FP
  let directory = $env.PRJ_DATA_DIR | path join $"idr-rotate-keys-(random chars)" | path expand
  mkdir $directory
  chmod 0700 $directory
  try {
    mut candidates = []
    for update in $updates {
      let filename = $update.path | path relative-to $root
      let file_directory = $directory | path join ($candidates | length | into string)
      let config = file-policy $new_policy (selected-rule $new_policy $filename) $file_directory
      let candidate_path = $file_directory | path join "secrets.enc.json"
      let candidate = with-env {SOPS_CONFIG: $config} {
        $update.updated | to json | sops encrypt --filename-override $candidate_path | complete | checked $"Could not encrypt ($filename)"
      }
      let encrypted = $candidate | from json
      for field in $update.privateFields {
        if $field in $update.updated and not ($encrypted | get $field | str starts-with "ENC[AES256_GCM,") {
          error make {msg: $"The SOPS policy must encrypt ($field)."}
        }
      }
      for field in ($update.changes | columns | where {|field| $field | str ends-with "_unencrypted" }) {
        if ($encrypted | get $field) != ($update.updated | get $field) {
          error make {msg: $"The SOPS policy must leave ($field) public."}
        }
      }
      let recipient_groups = [$encrypted.sops] ++ ($encrypted.sops.key_groups? | default [])
      let age_recipients = $recipient_groups | each {|group| $group.age? | default [] | each { get recipient } } | flatten
      if $old_age != "" and $old_age in $age_recipients {
        error make {msg: $"($filename) still includes the old host recipient."}
      }
      let verified = $candidate | sops decrypt --input-type json --output-type json | complete | checked $"A remaining operator recipient must be able to decrypt ($filename)" | from json
      if $verified != $update.updated {
        error make {msg: $"($filename) failed verification."}
      }
      $candidate | save $candidate_path
      $candidates = $candidates | append {path: $update.path, original: $update.original, candidate: $candidate_path}
    }

    let files = if $old_age == "" { [] } else {
      git ls-files --cached --others --exclude-standard -z -- '*.enc.json' '*.enc.yaml' '*.enc.bin'
        | complete | checked "Could not list repository secret files"
        | split row (char nul) | where {|file| $file != "" and ($file | path exists) } | uniq
    }
    for file in $files {
      if ($file | path expand) in $candidates.path {
        continue
      }
      let rules = $policy.creation_rules | where {|rule| $file =~ ($rule.path_regex? | default "") }
      if ($rules | is-empty) {
        continue
      }
      let rule = $rules | first
      let new_rule = selected-rule $new_policy $file
      if $rule == $new_rule {
        continue
      }
      let path = writable-file $file $root
      let original = open --raw $path
      let file_directory = $directory | path join ($candidates | length | into string)
      let config = file-policy $new_policy $new_rule $file_directory
      let candidate = $file_directory | path join $"secrets.enc.($file | path parse | get extension)"
      $original | save $candidate
      with-env {SOPS_CONFIG: $config} {
        sops updatekeys --yes $candidate | complete | checked $"Could not update recipients for ($file)" | ignore
        # Recipient changes alone leave the data key accessible through older ciphertext.
        sops rotate --in-place $candidate | complete | checked $"Could not rotate the data key for ($file)" | ignore
      }
      sops decrypt $candidate | complete | checked $"A remaining operator recipient must be able to decrypt ($file)" | ignore
      $candidates = $candidates | append {path: $path, original: $original, candidate: $candidate}
    }

    for file in $candidates {
      if (open --raw $file.path) != $file.original {
        error make {msg: $"($file.path) changed while planning the rotation; no files were replaced."}
      }
    }
    for file in $candidates {
      open --raw $file.candidate | save-atomic $file.path
      print $"Rotated ($file.path | path relative-to $root)"
    }
  } finally {|error|
    rm -rf $directory
    if $error != null {
      error make $error
    }
  }
}

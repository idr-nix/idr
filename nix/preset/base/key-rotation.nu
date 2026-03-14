def header-options [device: record] {
  if $device.header == null { [] } else { [--header $device.header] }
}

def key-slot [device: record, key_file: path, --slot: string] {
  let options = if $slot == null { [] } else { [--key-slot $slot] }
  # A TPM or keyring token must not satisfy the supplied key's verification.
  let checked = (cryptsetup open --type luks --test-passphrase --verbose --batch-mode
    --token-type idr-disk-key --disable-external-tokens
    ...(header-options $device) ...$options --key-file $key_file $device.device | complete)
  match $checked.exit_code {
    0 => ($checked.stdout | lines | parse --regex '^Key slot (?<slot>[0-9]+) unlocked\.$' | get 0.slot)
    2 => null
    _ => { error make {msg: $"Could not check a disk key for ($device.device): ($checked.stderr | str trim)"} }
  }
}

def disk-metadata [device: record] {
  let result = cryptsetup luksDump --dump-json-metadata ...(header-options $device) $device.device | complete
  if $result.exit_code != 0 {
    error make {msg: $"Could not read LUKS2 metadata for ($device.device): ($result.stderr | str trim)"}
  }
  $result.stdout | from json
}

def mark-slot [device: record, slot: string] {
  let metadata = disk-metadata $device
  let token = $metadata.tokens | transpose id value | where value.type == "idr-disk-key" | first 1 | get 0?
  let slots = $token.value?.keyslots? | default []
  if $slot in $slots {
    return
  }
  let options = if $token == null { [] } else { [--token-id $token.id --token-replace] }
  let imported = {type: "idr-disk-key", keyslots: ($slots | append $slot)} | to json
    | cryptsetup token import --json-file - ...(header-options $device) ...$options $device.device | complete
  if $imported.exit_code != 0 {
    error make {msg: $"Could not mark the IDR keyslot on ($device.device): ($imported.stderr | str trim)"}
  }
}

def desired-key [manifest: record] {
  let content = open --raw $manifest.keyFile
  let hash = $content | hash sha256
  if $manifest.keyHash != null and $hash != $manifest.keyHash {
    error make {msg: $"The SOPS disk key does not match its declared hash: ($manifest.keyFile)"}
  }

  {content: $content, hash: $hash, path: ($manifest.directory | path join "keys" $hash)}
}

def cache-key [manifest: record, content: string] {
  let path = $manifest.directory | path join "keys" ($content | hash sha256)
  mkdir ($path | path dirname)
  let staged = $manifest.directory | path join "key.new"
  $content | save --force $staged
  mv --force $staged $path
  $path
}

def recover-key [manifest: record, bundle: record] {
  let directory = $manifest.directory | path join "recovery"
  mut content = ""
  try {
    let recovered = with-env {XDG_RUNTIME_DIR: $manifest.directory} {
      ^$bundle.installer -ignore-passwd $bundle.manifest | complete
    }
    if $recovered.exit_code != 0 {
      error make {msg: $"Could not recover the disk key: ($recovered.stderr | str trim)"}
    }
    $content = open --raw ($directory | path join "secrets/idr-disk-key")
    if $bundle.keyHash != null and ($content | hash sha256) != $bundle.keyHash {
      error make {msg: "The recovered disk key does not match its declared hash."}
    }
    null
  } finally {|error|
    rm --recursive --force $directory
    if $error != null {
      error make $error
    }
  }
  $content
}

def publish-recovery [manifest: record, desired: record] {
  let recovery = $manifest.recovery
  if ($recovery.current | path exists) {
    if ($recovery.current | path expand) == $recovery.bundle {
      return
    }
    let current = open --raw $recovery.current | from json
    if $current.keyHash == $desired.hash {
      return
    }
  }

  let candidate = open $recovery.bundle
  if (recover-key $manifest $candidate | hash sha256) != $desired.hash {
    error make {msg: "The recovery bundle does not contain the declared disk key. Existing keyslots were kept."}
  }

  let directory = $recovery.current | path dirname
  mkdir $directory
  let rooted = nix-store --realise $recovery.bundle --add-root $recovery.current | complete
  if $rooted.exit_code != 0 {
    error make {msg: $"Could not preserve disk-key recovery data: ($rooted.stderr | str trim)"}
  }
}

def cached-keys [manifest: record] {
  ls ($manifest.directory | path join "keys") | where type == file | get name
}

def main [] {}

def "main prepare" [manifest_file: path] {
  ulimit --core-size 0
  $env.LC_ALL = "C"
  let manifest = open $manifest_file
  let desired = desired-key $manifest
  cache-key $manifest $desired.content | ignore
  mut previous_keys = cached-keys $manifest | where $it != $desired.path

  for device in $manifest.devices {
    let slot = key-slot $device $desired.path
    if $slot != null {
      mark-slot $device $slot
      continue
    }

    mut previous = $previous_keys | where {|key| (key-slot $device $key) != null } | first 1 | get 0?
    if $previous == null and ($manifest.recovery.current | path exists) {
      let recovered = recover-key $manifest (open --raw $manifest.recovery.current | from json)
      let path = cache-key $manifest $recovered
      $previous_keys = $previous_keys | append $path | uniq
      if (key-slot $device $path) != null {
        $previous = $path
      }
    }
    if $previous == null {
      error make {msg: $"No cached disk key unlocks ($device.device). Activate the current disk key before rotating it."}
    }

    mark-slot $device (key-slot $device $previous)
    print $"Adding the declared disk key to ($device.device)."
    let added = cryptsetup luksAddKey --batch-mode ...(header-options $device) --key-file $previous $device.device $desired.path | complete
    if $added.exit_code != 0 {
      error make {msg: $"Could not add a disk key to ($device.device): ($added.stderr | str trim)"}
    }
    let slot = key-slot $device $desired.path
    if $slot == null {
      error make {msg: $"The new key did not unlock ($device.device) after enrollment. Existing keyslots were kept."}
    }
    mark-slot $device $slot
  }
}

def "main revoke" [manifest_file: path] {
  ulimit --core-size 0
  $env.LC_ALL = "C"
  umask rwx------ | ignore
  let manifest = open $manifest_file
  let desired = desired-key $manifest
  cache-key $manifest $desired.content | ignore

  # Verify every device before changing any slots.
  let devices = $manifest.devices | each {|device|
    let slot = key-slot $device $desired.path
    if $slot == null {
      error make {msg: $"The current disk key does not unlock ($device.device). Existing keyslots were kept."}
    }
    let metadata = disk-metadata $device
    $device | insert currentSlot $slot
      | insert managedSlots ($metadata.tokens | values | where type == "idr-disk-key" | get keyslots | flatten | uniq)
  }

  publish-recovery $manifest $desired
  let synced = sync -f ($manifest.recovery.current | path dirname) ($env.NIX_STATE_DIR? | default "/nix/var/nix" | path join "gcroots") | complete
  if $synced.exit_code != 0 {
    error make {msg: $"Could not persist disk-key recovery data: ($synced.stderr | str trim)"}
  }

  for device in $devices {
    for slot in ($device.managedSlots | where $it != $device.currentSlot) {
      if (key-slot $device $desired.path --slot $device.currentSlot) == null {
        error make {msg: $"The current disk key no longer unlocks ($device.device). Remaining slots were kept."}
      }
      print $"Removing old IDR keyslot ($slot) from ($device.device)."
      let removed = cryptsetup luksKillSlot --batch-mode ...(header-options $device) --key-file $desired.path $device.device $slot | complete
      if $removed.exit_code != 0 {
        error make {msg: $"Could not remove keyslot ($slot) from ($device.device): ($removed.stderr | str trim)"}
      }
    }
  }
  for previous in (cached-keys $manifest | where $it != $desired.path) {
    rm $previous
  }
}

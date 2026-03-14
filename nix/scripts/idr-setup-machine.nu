def main [
  machine_name: string
] {
  if "PRJ_ROOT" not-in $env {
    print "PRJ_ROOT environment variable is required."
    exit 1
  }

  cd $env.PRJ_ROOT

  if not ($env.PRJ_ROOT | path join "nix/machine" $machine_name | path exists) {
    print "Machine configuration does not exists"
    exit 1
  }

  let machine_dir = ($env.PRJ_ROOT | path join "nix/machine" $machine_name)
  let secrets_path = $machine_dir | path join "secrets.enc.json"
  let disk_key_path = $machine_dir | path join "disk-key.enc.json"
  let secrets = if ($secrets_path | path exists) {open $secrets_path} else {{}}

  mkdir ($env.PRJ_DATA_DIR | path join "machine-host-key")
  let ssh_key_path = ($env.PRJ_DATA_DIR | path join $"machine-host-key/($machine_name)")
  if "ssh_host_ed25519_key" not-in $secrets {
    if not ($ssh_key_path | path exists) {
      ssh-keygen -t ed25519 -N "" -C $machine_name -f $ssh_key_path
    }
    chmod 0600 $ssh_key_path $"($ssh_key_path).pub"

    let ssh_pub_key = open --raw $"($ssh_key_path).pub" | lines | first
    if ($secrets_path | path exists) and "sops" in $secrets {
      sops --in-place --set $"[("ssh_host_ed25519_key_pub_unencrypted" | to json --raw)] ($ssh_pub_key | to json --raw)" $secrets_path
      sops --in-place --set $"[("ssh_host_ed25519_key_age_pub_unencrypted" | to json --raw)] ($ssh_pub_key | ssh-to-age | to json --raw)" $secrets_path
    } else {
      $secrets
        | merge {
            "ssh_host_ed25519_key_pub_unencrypted": $ssh_pub_key
            "ssh_host_ed25519_key_age_pub_unencrypted": ($ssh_pub_key | ssh-to-age)
          }
        | save -f $secrets_path
      git add $secrets_path
      # Regenerate .sops.yaml
      nix --offline -L develop -c true
      try {
        sops --encrypt --in-place $secrets_path
        do --capture-errors { sops --decrypt $secrets_path } | ignore
      } catch {|err|
        $secrets | save -f $secrets_path
        error make $err.raw
      }
    }

    let ssh_key = (open --raw $ssh_key_path)
    sops --in-place --set $"[("ssh_host_ed25519_key" | to json --raw)] ($ssh_key | to json --raw)" $secrets_path
  }

  if ("initrd_ssh_host_ed25519_key" not-in $secrets) {
    let tmp_dir = $nu.temp-dir | path join $"idr-initrd-ssh-(random chars)"
    let initrd_ssh_key_path = $tmp_dir | path join "ssh_host_ed25519_key"

    try {
      do --capture-errors {
        mkdir $tmp_dir
        chmod 0700 $tmp_dir
        ssh-keygen -t ed25519 -N "" -C $machine_name -f $initrd_ssh_key_path
        chmod 0600 $initrd_ssh_key_path $"($initrd_ssh_key_path).pub"

        let initrd_ssh_key = (open --raw $initrd_ssh_key_path)
        let initrd_ssh_pub_key = open --raw $"($initrd_ssh_key_path).pub" | lines | first

        sops --in-place --set $"[("initrd_ssh_host_ed25519_key_pub_unencrypted" | to json --raw)] ($initrd_ssh_pub_key | to json --raw)" $secrets_path
        sops --in-place --set $"[("initrd_ssh_host_ed25519_key" | to json --raw)] ($initrd_ssh_key | to json --raw)" $secrets_path
      }
    } catch {|err|
      rm -rf $tmp_dir
      error make $err.raw
    }

    rm -rf $tmp_dir
  }

  if ("root_password" not-in $secrets) {
    let root_password = random chars --length 64
    let root_hashed_password = $root_password | mkpasswd --stdin
    sops --in-place --set $"[("root_password_hash_unencrypted" | to json --raw)] ($root_hashed_password | to json --raw)" $secrets_path
    sops --in-place --set $"[("root_password" | to json --raw)] ($root_password | to json --raw)" $secrets_path
  }

  if not ($disk_key_path | path exists) or "disk_key" not-in (open $disk_key_path) {
    let disk_key = random chars --length 64
    let encrypted = {
      disk_key: $disk_key
      disk_key_hash_unencrypted: ($disk_key | hash sha256)
    } | to json | sops encrypt --filename-override $disk_key_path
    $encrypted | save --force $disk_key_path
    git add $disk_key_path
  }

  # Regenerate .sops.yaml
  nix --offline -L develop -c true
}

def main [] {
  let team = open $env.IDR_TEAM_JSON_FILE
  if "IDR_USER" in $env and $env.IDR_USER in $team {
    let user = $team | get $env.IDR_USER
    if "agePublicKey" in $user and "IDR_SOPS_AGE_KEY_CMD" in $env and $user.agePublicKey == $env.SOPS_AGE_RECIPIENT {
      return (^$nu.current-exe -n --no-std-lib --no-history -c $env.IDR_SOPS_AGE_KEY_CMD)
    }
  }

  let host_key_dir = $env.PRJ_DATA_DIR | path join "machine-host-key"

  if ($host_key_dir | path exists) {
    let ssh_keys = ls -l $host_key_dir | where not ($it.name | str ends-with ".pub")
    $ssh_keys | each {|file|
      if $file.type == "file" {
        chmod og-wrx $file.name
      }
    }

    let ssh_keys = $ssh_keys | where (ssh-keygen -y -f $it.name | ssh-to-age) == $env.SOPS_AGE_RECIPIENT | take 1

    if ($ssh_keys | is-not-empty) {
      return ($ssh_keys | first | open --raw $in.name | ssh-to-age -private-key)
    }
  }
}

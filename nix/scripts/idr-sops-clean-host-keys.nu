def main [machine_secrets_path: path] {
  if (not ($env.PRJ_ROOT | path exists)
      or (ls --directory --long $env.PRJ_ROOT | first | get readonly)
  ) {
    exit 0
  }

  cd $env.PRJ_ROOT

  let host_keys_dir = ($env.PRJ_DATA_DIR | path join "machine-host-key")
  mkdir $host_keys_dir

  let priv_keys = ls $host_keys_dir | get name | where not ($it | str ends-with ".pub")
  if (($priv_keys | is-empty)
      or ("IDR_USER" not-in $env)
      or ("IDR_TEAM_JSON_FILE" not-in $env)
      or ("IDR_SOPS_AGE_KEY_CMD" not-in $env)
  ) {
    exit 0
  }

  let team = (open $env.IDR_TEAM_JSON_FILE)
  if ($env.IDR_USER not-in $team) {
    print $"($env.IDR_USER) must exist in team config."
    exit 1
  }

  let user = $team | get $env.IDR_USER
  if "agePublicKey" not-in $user {
    print $"Team member ($env.IDR_USER) must have agePublicKey field."
    exit 1
  }

  try {
    {test: 123}
      | to json
      | sops --config /dev/null encrypt --age $user.agePublicKey --filename-override "secrets.json"
      | sops decrypt --output /dev/null --filename-override "secrets.json"
  } catch {|err|
    print "IDR_USER specified, but sops decryption keys are not configured properly."
    print "Set IDR_SOPS_AGE_KEY_CMD to a command that outputs your age private key corresponding to agePublicKey from team config."
    exit 0
  }

  let machine_secrets = open $machine_secrets_path
  let machines = $machine_secrets | columns

  $priv_keys | where ($it | path basename) in $machines | par-each {|file|
    let name = $file | path basename
    let secrets_path = $machine_secrets | get $name
    if $secrets_path == null {
      return
    }
    let secrets = open $secrets_path
    if ("sops" in $secrets) {
      if $user.agePublicKey in ($secrets | get sops.age.recipient) {
        ^rm -f -- $file $"($file).pub"
      }
    }
  }

  ignore
}

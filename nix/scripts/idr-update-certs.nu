use idr-common.nu [save-atomic]

def cert-is-due [cert_name: string, cert: record] {
  let sops_file = $cert.sopsFile
  if not ($sops_file | path exists) {
    return true
  }

  let issue_date = open $sops_file | get -o $"($cert_name)_issue_date_unencrypted" | default ""
  $issue_date == "" or ($issue_date | into datetime) + 30day <= (date now)
}

def account-exists [email: string] {
  let server = $env.LEGO_SERVER? | default "https://acme-v02.api.letsencrypt.org/directory"
  let server_host = $server | url parse | get host
  let account_dir = [$env.LEGO_PATH "accounts" $server_host $email] | path join

  let account_file_exists = [$account_dir "account.json"] | path join | path exists
  let key_file_exists = [$account_dir "keys" $"($email).key"] | path join | path exists
  $account_file_exists and $key_file_exists
}

def issue-cert [cert_name: string, cert: record] {
  let cert_env = $cert.envRename | items {|k,v| {$k: ($env | get $v)}} | reduce --fold {} {|it acc| $acc | merge $it}

  with-env $cert_env {
    let flags = $cert.legoFlags ++ (if "--dns" not-in $cert.legoFlags or "--dns.propagation-wait" in $cert.legoFlags {[]} else {[
      "--dns.propagation-wait"
      "180s"
    ]})

    do --capture-errors {
      lego --pem -a -m $cert.email ...($flags) ...($cert.domains | each {|d| ["-d" $d]} | flatten) run
    }

    {cert_name: $cert_name, cert: $cert}
  }
}

def save-cert [issued: record] {
  let cert_name = $issued.cert_name
  let cert = $issued.cert
  let sops_file = $cert.sopsFile
  let first_domain = ($cert.domains | first | str replace --all "*" "_")
  let cert_value = (open --raw $"($env.LEGO_PATH)/certificates/($first_domain).crt")
  let cert_key = (open --raw $"($env.LEGO_PATH)/certificates/($first_domain).key")
  let cert_pem = (open --raw $"($env.LEGO_PATH)/certificates/($first_domain).pem")

  let secrets = if ($sops_file | path exists) {
    sops decrypt --output-type json $sops_file | from json
  } else { {} }
  let encrypted = $secrets | merge {
    $"($cert_name)_cert": $cert_value
    $"($cert_name)_cert_key": $cert_key
    $"($cert_name)_cert_pem": $cert_pem
    $"($cert_name)_issue_date_unencrypted": (date now | format date "%+")
  } | to json | sops encrypt --input-type json --filename-override $sops_file | complete
  if $encrypted.exit_code != 0 {
    error make {msg: $"Could not encrypt ($sops_file): ($encrypted.stderr | str trim)"}
  }
  $encrypted.stdout | save-atomic $sops_file

  git add -- $sops_file
}

def main [...cert_names: string] {
  umask rwx------ | ignore
  ulimit --core-size 0
  cd ($env.PRJ_ROOT? | default $env.PWD)
  let certs = open $env.IDR_CERTS_FILE
  let available_names = ($certs | columns)
  let requested_names = ($cert_names | uniq)
  let unknown_names = ($requested_names | where {|name| $name not-in $available_names})

  if not ($unknown_names | is-empty) {
    error make {msg: $"Unknown certificate names: ($unknown_names | str join ', ')"}
  }

  if "LEGO_PATH" not-in $env {
    $env.LEGO_PATH = $env.PRJ_DATA_DIR? | default ($env.PWD | path join ".data") | path join "lego" | path expand
  }
  mkdir $env.LEGO_PATH

  let selected_certs = $certs | transpose name config | where {|cert|
    ($requested_names | is-empty) or $cert.name in $requested_names
  }
  let due_certs = $selected_certs | where {|cert|
    let due = cert-is-due $cert.name $cert.config
    if not $due {
      print $"Certificate ($cert.name) already up to date."
    }
    $due
  }
  if ($due_certs | is-empty) {
    return
  }

  # Lego has no account-only registration command. Issue one real certificate
  # per ACME account serially, so a missing account is initialized once, then
  # issue the remaining certificates in parallel.
  let bootstrap_names = ($due_certs | each {|cert| $cert.config.email} | uniq | where {|email| not (account-exists $email)} | each {|email|
    $due_certs | where {|cert| $cert.config.email == $email} | first | get name
  })

  let bootstrap_issued = ($due_certs | where {|cert| $cert.name in $bootstrap_names} | each {|cert| issue-cert $cert.name $cert.config})
  let parallel_certs = $due_certs | where {|cert| $cert.name not-in $bootstrap_names}
  let parallel_issued = if ($parallel_certs | is-empty) { [] } else {
    $parallel_certs | par-each {|cert| issue-cert $cert.name $cert.config}
  }

  # Multiple certificates can share one encrypted file. Save serially so
  # concurrent sops writes cannot overwrite one another.
  $bootstrap_issued | append $parallel_issued | each {|issued| save-cert $issued}
}

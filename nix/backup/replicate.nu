def main [manifest_file: path] {
  let target = open $manifest_file
  let credential = $env.CREDENTIALS_DIRECTORY? | default "" | path join "idr.workspace-id"
  let local_vm = $credential | path exists
  let host = if $local_vm {
    let workspace = open --raw $credential | str trim | split chars | chunks 4 | each { str join } | str join ":"
    let machine = $target.machineId | split chars | chunks 4 | each { str join } | str join ":"
    $"($target.networkPrefix):($workspace):($machine)"
  } else { $target.host }
  let options = if $local_vm { [-p ($target.port | into string)] } else { $target.sshOptions }
  let ssh_config = $env.RUNTIME_DIRECTORY | path join "ssh_config"
  let ssh_options = [
    -G -T -F /dev/null -l $target.user -i $target.identity
    -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none
    -o StrictHostKeyChecking=yes -o $"UserKnownHostsFile=($target.knownHosts)"
    -o UpdateHostKeys=no
    -o GlobalKnownHostsFile=/dev/null -o KnownHostsCommand=none
    -o VerifyHostKeyDNS=no -o NoHostAuthenticationForLocalhost=no
    -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3
  ] ++ $options ++ [$host]
  let rendered = ssh ...$ssh_options | complete
  if $rendered.exit_code != 0 {
    error make {msg: $"Could not configure backup SSH: ($rendered.stderr | str trim)"}
  }
  # A local alias keeps IPv6 colons out of Syncoid's host:dataset syntax.
  $rendered.stdout | str replace --regex '^host .+' $"Host ($target.alias)" | save --force $ssh_config

  let arguments = [
    --recursive --no-sync-snap --no-privilege-elevation --compress=none
    --sshconfig $ssh_config --sendoptions "w p"
    --recvoptions "u o readonly=on x mountpoint x syncoid:sync"
  ]

  for dataset in $target.datasets {
    let destination = $"($target.destination)/($dataset)"
    let parent = $destination | path dirname
    let exists = ^/run/booted-system/sw/bin/zfs list -H -o name $parent | complete
    if $exists.exit_code != 0 {
      do --capture-errors {
        ^/run/booted-system/sw/bin/zfs create -p -o canmount=off -o mountpoint=none $parent
      }
    }
    do --capture-errors {
      syncoid ...$arguments $"($target.user)@($target.alias):($dataset)" $destination
    }
  }
}

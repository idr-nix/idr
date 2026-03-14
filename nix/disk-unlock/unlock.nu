def main [manifest_path: string] {
  ulimit --core-size 0
  let manifest = open $manifest_path
  let name = head --bytes=256 | str trim
  let target = $manifest.targets | get --optional $name
  if $target == null {
    error make {msg: "Unknown disk-unlock target."}
  }

  let options = [
    "-T"
    "-F" "/dev/null"
    "-i" $manifest.sshPrivateKey
    "-p" ($target.port | into string)
    "-o" "BatchMode=yes"
    "-o" "IdentitiesOnly=yes"
    "-o" "IdentityAgent=none"
    "-o" "ControlMaster=no"
    "-o" "ControlPath=none"
    "-o" "StrictHostKeyChecking=yes"
    "-o" "KnownHostsCommand=none"
    "-o" "VerifyHostKeyDNS=no"
    "-o" "NoHostAuthenticationForLocalhost=no"
    "-o" $"UserKnownHostsFile=($target.knownHosts)"
    "-o" "GlobalKnownHostsFile=/dev/null"
    "-o" "ConnectTimeout=10"
    "-o" "ServerAliveInterval=5"
    "-o" "ServerAliveCountMax=1"
    "-o" "LogLevel=ERROR"
  ] ++ $target.sshOpts
  let disk_key = open --raw $target.diskKey
  let result = generate {|key| {out: $key, next: $key} } $disk_key
    | to text
    | ssh ...$options $"root@($target.host)"
    | complete
  if $result.exit_code != 0 {
    error make {msg: $"Could not unlock ($name): ($result.stderr | str trim)"}
  }
  print $"Sent disk key to ($name)."
}

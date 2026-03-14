use idr-target.nu [resolve-target ssh-arguments]

def --wrapped main [
  node: string
  --host: string
  --user: string
  --port: int
  --help(-h)
  ...ssh_options: string
] {
  let target = resolve-target $node
  let arguments = ssh-arguments $target {
    host: $host, user: $user, port: $port, options: (["-T"] ++ $ssh_options)
  }
  exec ssh ...$arguments /run/current-system/sw/bin/idr-revoke-old-disk-keys
}

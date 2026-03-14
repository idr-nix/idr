use idr-common.nu [workspace-id]
use idr-qemu-network.nu [address]

export def scan-host-keys [vm_address: string, port: int] {
  let scanned = ssh-keyscan -6 -T 2 -p $port -t ed25519 $vm_address | complete
  if $scanned.exit_code != 0 {
    return []
  }
  $scanned.stdout | lines | each {|line| $line | split row " " | skip 1 | first 2 | str join " " }
}

export def has-host-key [vm_address: string, port: int, public_keys: list<string>] {
  let expected_keys = $public_keys | each {|key| $key | split row " " | first 2 | str join " " }
  scan-host-keys $vm_address $port | any {|key| $key in $expected_keys }
}

def main [prefix: string, machine_id: string, port: int, public_key: string, --sops-file: path] {
  let vm_address = address $prefix (workspace-id) $machine_id
  let public_key = if $sops_file == null {
    $public_key
  } else {
    open ($env.PRJ_ROOT | path join $sops_file) | get ssh_host_ed25519_key_pub_unencrypted
  }
  # The running system's host key distinguishes it from initrd and installer SSH.
  if not (has-host-key $vm_address $port [$public_key]) {
    exit 1
  }
}

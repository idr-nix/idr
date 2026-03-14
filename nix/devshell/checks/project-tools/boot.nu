use std/assert

def wait-for [description: string, ready: closure] {
  let deadline = (date now) + 3min
  while not (do $ready) {
    if (date now) >= $deadline {
      error make {msg: $"Timed out waiting for ($description)"}
    }
    sleep 1sec
  }
}

def --wrapped remote [...args: string] {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new vm-test-machine ...$args
}

def serves-key [ip: string, key: string] {
  let expected = $key | split row " " | first 2 | str join " "
  let scan = ssh-keyscan -6 -T 2 -t ed25519 $ip | complete
  $scan.stdout | lines | any {|line|
    ($line | split row " " | skip 1 | str join " ") == $expected
  }
}

def main [] {
  let secrets = open nix/machine/test-machine/secrets.enc.json
  let id = open --raw nix/machine/test-machine/configuration.nix
    | parse --regex 'id = "(?<id>[0-9a-f]{12})"' | get 0.id
  let prefix = nix eval --raw '.#nixosConfigurations.test-machine.config.idr.qemu.networkPrefix'
  let machine_address = $id | split chars | chunks 4 | each { str join } | str join ":"
  let ip = $"($prefix):0000:0000:($machine_address)"
  let host = open --raw /etc/machine-id | str trim
  let images = $env.PRJ_DATA_DIR | path join $host "test-machine/qemu"
  mkdir $images
  glob $"($env.PRJ_DATA_DIR)/images/qcow2/*.qcow2" | each {|file| mv $file $images }

  let ready = { serves-key $ip $secrets.ssh_host_ed25519_key_pub_unencrypted }
  try {
    # One boot deliberately stops at initrd so the operator CLI is exercised.
    with-env {IDR_QEMU_AUTO_UNLOCK: "false"} { "" | setsid idr -t=false -D }
    idr process start vm-test-machine
    wait-for "initrd SSH" { serves-key $ip $secrets.initrd_ssh_host_ed25519_key_pub_unencrypted }
    assert not (do $ready) "A locked VM must not report the running system's host key"
    idr-unlock-disks vm-test-machine --timeout 2min
    wait-for "the unlocked system" $ready
    wait-for "Process Compose readiness" {
      (idr process get vm-test-machine -o json | from json | get 0.is_ready) == "Ready"
    }
    assert equal (remote zpool status -x | str trim) "all pools are healthy"
    remote test -b /dev/disk/by-id/nvme-eui.002538b141a23dfc
    remote test -b /dev/disk/by-id/nvme-eui.002538b141a261e6
    let swaps = remote swapon --show=NAME --noheadings --raw | lines
    assert equal ($swaps | length) 2
    for swap in $swaps {
      assert equal (remote lsblk --nodeps --noheadings --output TYPE $swap | str trim) "crypt"
    }
    remote touch /root/volatile-test /persist/persistent-test
    remote sync
    let first_boot = remote cat /proc/sys/kernel/random/boot_id | str trim
    let host_id = remote cat /etc/machine-id | str trim
    let key_file = $images | path join "ssh/secrets.enc.json"
    let encrypted_key = open --raw $key_file
    assert (open $key_file | get ssh_private_key | str starts-with "ENC[AES256_GCM,")
    assert equal (open $key_file | get sops.age.recipient | sort) ($secrets.sops.age.recipient | sort)
    idr down

    # The default runner unlocks automatically, reusing the encrypted client key.
    "" | setsid idr -t=false -D
    idr process start vm-test-machine
    wait-for "automatic disk unlock" $ready
    assert not equal (remote cat /proc/sys/kernel/random/boot_id | str trim) $first_boot
    assert equal (remote cat /etc/machine-id | str trim) $host_id
    remote test -f /persist/persistent-test
    assert equal (do { remote test -e /root/volatile-test } | complete | get exit_code) 1
    assert equal (open --raw $key_file) $encrypted_key "Restarting a VM must reuse its encrypted SSH key"

    # The same QEMU process must also unlock a subsequent guest reboot.
    let previous_boot = remote cat /proc/sys/kernel/random/boot_id | str trim
    remote systemctl reboot
    wait-for "the guest to leave the running system" { not (do $ready) }
    wait-for "automatic unlock after reboot" $ready
    assert not equal (remote cat /proc/sys/kernel/random/boot_id | str trim) $previous_boot
    remote test -f /persist/persistent-test
    null
  } finally {|error|
    if $error != null {
      idr process logs vm-test-machine | complete | get stdout | print --stderr
      idr down | complete | ignore
      error make $error
    }
  }
}

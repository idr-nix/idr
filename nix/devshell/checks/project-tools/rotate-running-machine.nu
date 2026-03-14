use std/assert

def key-accepted [device: string, key: string] {
  let result = do {
    $key | ssh -T -o BatchMode=yes vm-test-machine cryptsetup open --test-passphrase --token-type idr-disk-key --disable-external-tokens --key-file /dev/stdin $device
  } | complete
  if $result.exit_code not-in [0 2] {
    error make {msg: $"Could not check a disk key: ($result.stderr)"}
  }
  $result.exit_code == 0
}

def main [] {
  assert equal (open --raw generated/copied.txt) "generated\n"
  assert equal (open --raw ($env.PRJ_DATA_DIR | path join "generated-hooks")) "xx" "Unchanged files must not rerun postWrite"
  let secret = "nix/machine/test-machine/disk-key.enc.json"
  let old_key = sops decrypt --extract '["disk_key"]' $secret
  let devices = (nix eval --json '.#nixosConfigurations.test-machine.config.boot.initrd.luks.devices'
    --apply 'devices: map (device: device.device) (builtins.attrValues devices)' | from json)
  assert equal ($devices | length) 2
  let host = open --raw /etc/machine-id | str trim
  let client_key = $env.PRJ_DATA_DIR | path join $host "test-machine/qemu/ssh/secrets.enc.json"
  sops decrypt --extract '["ssh_private_key"]' $client_key | hash sha256
    | save ($env.PRJ_DATA_DIR | path join "previous-client-key-hash")

  try {
    idr-rotate-keys vm-test-machine --force
    idr-copy-extra-files vm-test-machine
    let repeated_copy = idr-copy-extra-files vm-test-machine
    assert ($repeated_copy | str contains "Unchanged")
    assert not ($repeated_copy | str contains "Copied") "Identical extra files must not be uploaded again"
    deploy -s .#vm-test-machine -- -L

    let key = sops decrypt --extract '["disk_key"]' $secret
    for device in $devices {
      assert (key-accepted $device $key) "The deployed key must unlock every managed disk"
      assert (key-accepted $device $old_key) "Deployment must preserve the previous disk key until explicit revocation"
    }
    idr-revoke-old-disk-keys vm-test-machine
    for device in $devices {
      assert (key-accepted $device $key) "Revocation must preserve the deployed disk key"
      assert not (key-accepted $device $old_key) "Explicit revocation must remove the previous disk key"
    }
    ssh -o BatchMode=yes vm-test-machine test -f /persist/persistent-test

    # Reboot the guest without restarting QEMU, whose unlock worker predates rotation.
    let qemu_pid = ps | where name =~ "qemu-system" | get pid | first
    let previous_boot = ssh -o BatchMode=yes vm-test-machine cat /proc/sys/kernel/random/boot_id | str trim
    ssh -o BatchMode=yes vm-test-machine systemctl reboot
    let deadline = (date now) + 3min
    loop {
      let boot = do {
        ssh -o BatchMode=yes -o ConnectTimeout=2 vm-test-machine cat /proc/sys/kernel/random/boot_id
      } | complete
      if $boot.exit_code == 0 and ($boot.stdout | str trim) != $previous_boot {
        if (idr process get vm-test-machine -o json | from json | get 0.is_ready) == "Ready" {
          break
        }
      }
      if (date now) >= $deadline {
        error make {msg: "The rotated system did not become ready after a guest reboot"}
      }
      sleep 2sec
    }
    assert (ps | any {|process| $process.pid == $qemu_pid }) "Guest reboot must retain the original QEMU process"
    ssh -o BatchMode=yes vm-test-machine test -f /persist/persistent-test
    null
  } finally {|error|
    if $error != null {
      idr process logs vm-test-machine | complete | get stdout | print --stderr
    }
    idr down | complete | ignore
    if $error != null {
      error make $error
    }
  }
}

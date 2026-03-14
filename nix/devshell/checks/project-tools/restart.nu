use std/assert

def main [] {
  let host = open --raw /etc/machine-id | str trim
  let key_file = $env.PRJ_DATA_DIR | path join $host "test-machine/qemu/ssh/secrets.enc.json"
  let old_hash = open --raw ($env.PRJ_DATA_DIR | path join "previous-client-key-hash")
  try {
    "" | setsid idr -t=false -D
    idr process start vm-test-machine
    let deadline = (date now) + 3min
    while (idr process get vm-test-machine -o json | from json | get 0.is_ready) != "Ready" {
      if (date now) >= $deadline {
        error make {msg: "The rotated system did not unlock and become ready"}
      }
      sleep 1sec
    }
    let key_hash = sops decrypt --extract '["ssh_private_key"]' $key_file | hash sha256
    assert not equal $key_hash $old_hash "Changed recipients require a new VM client key"
    let recipients = open nix/machine/test-machine/secrets.enc.json | get sops.age.recipient | sort
    assert equal (open $key_file | get sops.age.recipient | sort) $recipients
    assert (open $key_file | get ssh_private_key | str starts-with "ENC[AES256_GCM,")
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

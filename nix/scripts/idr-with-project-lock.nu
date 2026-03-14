def --wrapped main [command: string, ...args: string] {
  let lock_path = $env.PRJ_DATA_DIR | path join ".idr-project.lock"
  let owner = random uuid
  let deadline = (date now) + 30sec
  mkdir $env.PRJ_DATA_DIR

  try {
    loop {
      # Record ownership atomically, including when acquisition is interrupted.
      if (^ln -sT -- $owner $lock_path | complete | get exit_code) == 0 {
        break
      }
      if (date now) >= $deadline {
        error make {msg: $"Could not acquire project lock ($lock_path). Another startup may still be running; otherwise, remove the stale lock."}
      }
      sleep 100ms
    }

    ^$command ...$args
    null
  } finally {|error|
    let lock = ^readlink -- $lock_path | complete
    if $lock.exit_code == 0 and ($lock.stdout | str trim) == $owner {
      ^rm -- $lock_path
      null
    }
    if $error != null {
      if $error.exit_code? == null {
        error make $error
      }
      exit $error.exit_code
    }
  }
}

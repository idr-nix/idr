def main [] {
  ulimit --core-size 0
  umask rwx------ | ignore
  let directory = do --capture-errors { mktemp --directory --tmpdir idr-ssh-key.XXXXXXXXXX } | str trim
  let key = $directory | path join key
  mut pair = {private: "", public: ""}
  try {
    do --capture-errors { ssh-keygen -q -t ed25519 -N '' -C '' -f $key }
    $pair = {
      private: (open --raw $key)
      public: (open --raw $"($key).pub" | str trim)
    }
    null
  } finally {|error|
    # External cleanup still runs when Nu's cancellation flag is set.
    let cleanup = ^rm --recursive --force -- $directory | complete
    if $cleanup.exit_code != 0 {
      error make {msg: $"Could not remove the temporary SSH key: ($cleanup.stderr | str trim)"}
    }
    if $error != null { error make $error }
  }
  $pair | to json --raw
}

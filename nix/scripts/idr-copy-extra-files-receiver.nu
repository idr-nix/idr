def main [] {}

def "main check" [destination: path, expected_hash: string] {
  if ($destination | path exists) and (open --raw $destination | hash sha256) == $expected_hash {
    "unchanged"
  } else {
    "changed"
  }
}

def "main install" [destination: path, expected_hash: string] {
  ulimit --core-size 0
  let content = open --raw /dev/stdin | into binary
  if ($content | hash sha256) != $expected_hash {
    error make {msg: $"Content hash does not match for ($destination)."}
  }

  let directory = $destination | path dirname
  let temporary_directory = $directory | path join $".idr-copy-(random uuid)"
  mkdir $directory $temporary_directory
  try {
    chmod 0700 $temporary_directory
    let temporary_file = $temporary_directory | path join "content"
    $content | save $temporary_file
    chmod 0600 $temporary_file
    chown root:root $temporary_file
    # Nu's mv treats an existing directory as a target directory, so require a file here.
    ^mv --force --no-target-directory -- $temporary_file $destination
    null
  } finally {|error|
    rm --recursive --force $temporary_directory
    if $error != null {
      error make $error
    }
  }
}

use idr-common.nu [save-atomic]
use idr-sops.nu [decrypt-if-accessible]

def has-sops-metadata [file: path] {
  # Machine setup writes plaintext placeholders before its first encryption.
  # Parse the document instead of using `sops filestatus`, which also reports
  # false for damaged metadata (for example a missing MAC or version).
  let document = if ($file | str ends-with ".enc.bin") {
    open --raw $file | from json
  } else {
    open $file
  }
  let documents = if ($document | describe | str starts-with "record") {
    [$document]
  } else if ($document | describe) =~ '^(list|table)' {
    $document
  } else {
    []
  }
  $documents | any {|document|
    ($document | describe | str starts-with "record") and ("sops" in $document)
  }
}

def main [--pending] {
  if not ($env.PRJ_ROOT | path exists) or (ls --directory --long $env.PRJ_ROOT | first | get readonly) {
    return
  }
  cd $env.PRJ_ROOT

  let pending_files_path = $env.PRJ_DATA_DIR | path join "pending-sops-updatekeys.json"
  let files = if $pending {
    if ($pending_files_path | path exists) {open $pending_files_path} else {[]}
  } else {
    fd --hidden --exclude .git -t f -e enc.json -e enc.bin -e enc.yaml --print0 --strip-cwd-prefix
      | split row (char nul)
      | where $it != ""
  } | where ($it | path exists)
    | where {|file| has-sops-metadata $file}

  if ($files | is-empty) {
    rm --force $pending_files_path
    return
  }
  $files | to json | save-atomic $pending_files_path

  let remaining = $files | par-each {|file|
    if (decrypt-if-accessible --output /dev/null $file) == null {
      return $file
    }
    sops updatekeys -y $file
    null
  }
  $files | where $it not-in $remaining | each {|file|
    git add $file
  } | ignore

  if ($remaining | is-empty) {
    rm --force $pending_files_path
  } else {
    $remaining | to json | save-atomic $pending_files_path
  }
}

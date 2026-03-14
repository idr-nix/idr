def main [] {
  if not ($env.PRJ_ROOT | path exists) or (ls --directory --long $env.PRJ_ROOT | first | get readonly) {
    exit 0
  }

  cd $env.PRJ_ROOT

  let files = open $env.IDR_FILES_PATH

  $files | transpose name file | par-each {|entry|
    let file_path = ($env.PRJ_ROOT | path join $entry.name)
    let file = $entry.file
    let is_symlink = ($file_path | path type) == "symlink"
    let changed = if not ($file_path | path exists) {
      true
    } else if $file.copy {
      $is_symlink or (open --raw $file.content | hash sha256) != (open --raw $file_path | hash sha256)
    } else {
      $file.content != (ls --directory -l $file_path | get target.0)
    }

    if $changed {
      mkdir ($file_path | path dirname)
      if $file.copy {
        if $is_symlink {
          rm $file_path
        }
        ^cp -f $file.content $file_path
      } else {
        ln -Tsf $file.content $file_path
      }

      if $file.postWrite != "" {
        try {
          do --capture-errors {
            bash -o pipefail -eu -c $file.postWrite
          }
        } catch {|err|
          rm --force $file_path
          error make $err.raw
        }
      }
    }
  }

  ignore
}

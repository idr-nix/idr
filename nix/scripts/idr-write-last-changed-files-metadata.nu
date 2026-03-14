use idr-common.nu [save-atomic]

def main [] {
  if not ($env.PRJ_ROOT | path exists) or (ls --directory --long $env.PRJ_ROOT | first | get readonly) {
    exit 0
  }

  cd $env.PRJ_ROOT

  let changed_files_path = $env.PRJ_DATA_DIR | path join "last-changed-files.json"
  if ($changed_files_path | path exists) {
    let changed_files = open $changed_files_path
    let now = date now | format date "%+"
    let files = (fd --hidden --exclude .git -t f --color never --changed-within $changed_files.modified_at --print0 --strip-cwd-prefix
      | split row (char nul)
      | where $it != ""
    )

    if ($files | is-not-empty) or ($changed_files.files | is-not-empty) {
      $files
        | {modified_at: $now, files: $in}
        | to json
        | save-atomic $changed_files_path
    }
  } else {
    mkdir ($changed_files_path | path dirname)
    let now = date now | format date "%+"
    git status --porcelain -z --untracked-files=all --no-renames
      | split row (char nul)
      | where $it =~ '^[ MA?][ M?] '
      | str substring 3..
      | {modified_at: $now, files: $in}
      | to json
      | save-atomic $changed_files_path
  }

  ignore
}

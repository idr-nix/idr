use idr-common.nu [save-atomic]

def main [] {
  if not ($env.PRJ_ROOT | path exists) or (ls --directory --long $env.PRJ_ROOT | first | get readonly) {
    exit 0
  }

  let interval = if "IDR_ROTATION_DEFAULT_INTERVAL" in $env {$env.IDR_ROTATION_DEFAULT_INTERVAL} else {"90day"}
  let rotation = $"interval=($interval) modified_ts=(date now | format date "%s")"

  cd $env.PRJ_ROOT

  let pending_files_path = $env.PRJ_DATA_DIR | path join "pending-rotation-files.json"
  let pending_files = if ($pending_files_path | path exists) {open $pending_files_path} else {[]}
  let changed_files_path = $env.PRJ_DATA_DIR | path join "last-changed-files.json"
  let changed_files = if ($changed_files_path | path exists) {open $changed_files_path | get files} else {[]}
  let files = ($pending_files ++ $changed_files
    | uniq
    | where ($it | str ends-with ".enc.json") or ($it | str ends-with ".enc.yaml")
    | where ($it | path exists)
  )

  if ($files | is-not-empty) {
    $files | to json | save-atomic $pending_files_path

    $files | par-each {|file|
      let raw_secrets = open $file | default {}
      if ("sops" in $raw_secrets) {
        let columns = $raw_secrets | columns | where $it != "sops"
        let need_rotation_metadata = {|col|
          not ($col | str ends-with "@_unencrypted") and ($"($col)@_unencrypted" not-in $raw_secrets)
        }

        if ($columns | any $need_rotation_metadata) or ($columns != ($columns | sort)) {
          let secrets = sops --decrypt $file | if ($file | str ends-with ".yaml") {
            # Preserve the final newline used by YAML block scalars.
            decode utf-8 | from yaml
          } else {
            from json
          }

          let encrypted = ($secrets
            | transpose key value
            | append ($columns | where $need_rotation_metadata | each {|col| {key: $"($col)@_unencrypted", value: $rotation}})
            | sort-by key
            | transpose -rd
            | if ($file | str ends-with ".yaml") {to yaml} else {to json}
            | sops encrypt --filename-override $file
          )

          $encrypted | save-atomic $file
        }
      }
    }
  }

  rm --force $pending_files_path

  ignore
}

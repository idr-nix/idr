use idr-common.nu [host-data-dir]

def --wrapped main [
  $cmd: string = ""
  ...args
] {
  if $cmd not-in ["help" "h" "--help" "-h"] {
    run-external $env.IDR_BACKGROUND_BUILD ready search-options
    if $env.LAST_EXIT_CODE != 0 { exit $env.LAST_EXIT_CODE }
  }
  let data_dir = host-data-dir
  mkdir $data_dir
  cd $data_dir

  if ($cmd | is-empty) {
    run-external $env.IDR_NIX_SEARCH_TV_PATH
  } else {
    let config_args = if $cmd in ["help" "h" "--help" "-h"] {[]} else {["--config" $env.IDR_NIX_SEARCH_TV_CONFIG_PATH]}
    run-external $env.IDR_NIX_SEARCH_TV_PATH $cmd ...$config_args ...($args)
  }
}

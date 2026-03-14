use idr-common.nu [host-data-dir host-socket-prefix save-atomic workspace-id]

def main [template: path, --ssh-opts] {
  cd $env.PRJ_ROOT
  let workspace = workspace-id
  let workspace_address = $workspace | split chars | chunks 4 | each { str join } | str join ":"
  let config = open --raw $template
    | str replace --all "@WORKSPACE_ID@" $workspace_address
    | str replace --all "@AGENT_PREFIX@" (host-socket-prefix "ssh")

  let directory = host-data-dir | path join "ssh"
  mkdir $directory
  let config_path = $directory | path join $"($workspace).conf" | path expand
  if not ($config_path | path exists) or (open --raw $config_path) != $config {
    $config | save-atomic $config_path
  }
  if $ssh_opts {
    $"-F ($config_path | to nuon)"
  } else {
    $config_path
  }
}

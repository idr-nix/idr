use idr-nix-strings.nu nix-identifier

def --wrapped main [
  --help (-h) # Display the help message for this command.
  module_name: string # Module name; lowercase and dash-separated is recommended.
  ...copier_args # Additional arguments forwarded to Copier.
] {
  let pattern = "^[a-zA-Z0-9]([a-zA-Z0-9\\-_]*[a-zA-Z0-9])?$"
  if $module_name !~ $pattern {
    error make {msg: $"Module name must match ($pattern)"}
  }

  let namespace = if ($env.IDR_PROJECT_NAMESPACE? | default "") == "" {
    let project_name = $env.PRJ_ROOT | path basename | str replace --all --regex '[^a-zA-Z0-9_-]' '-'
    [idr project $project_name]
  } else {
    $env.IDR_PROJECT_NAMESPACE | split row '.'
  }
  if ($namespace | any {is-empty}) {
    error make {msg: "IDR_PROJECT_NAMESPACE must contain nonempty, dot-separated names."}
  }
  let namespace_nix = $namespace | each {|part| nix-identifier $part} | str join '.'
  let data = [
    -d $"name=($module_name)"
    -d $"name_nix=(nix-identifier $module_name)"
    -d $"namespace=($namespace_nix)"
  ]

  cd $env.PRJ_ROOT
  exec copier copy --trust $env.IDR_MODULE_TEMPLATE nix ...$copier_args ...$data
}

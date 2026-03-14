def --wrapped main [
  --help (-h) # Display the help message for this command.
  module_name: string # Module name; lowercase and dash-separated is recommended.
  ...copier_args # Additional arguments forwarded to Copier.
] {
  let pattern = "^[a-zA-Z0-9]([a-zA-Z0-9\\-_]*[a-zA-Z0-9])?$"
  if $module_name !~ $pattern {
    error make {msg: $"Module name must match ($pattern)"}
  }

  cd $env.PRJ_ROOT
  exec copier copy --trust $env.IDR_MODULE_TEMPLATE nix ...$copier_args -d $"name=($module_name)"
}

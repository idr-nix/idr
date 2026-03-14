def --wrapped main [
  --help (-h) # Display the help message for this command.
  role_name: string # Role name; lowercase and dash-separated is recommended.
  ...copier_args # Additional arguments forwarded to Copier.
] {
  let pattern = "^[a-zA-Z0-9]([a-zA-Z0-9\\-_]*[a-zA-Z0-9])?$"
  if $role_name !~ $pattern {
    error make {msg: $"Role name must match ($pattern)"}
  }

  cd $env.PRJ_ROOT
  exec copier copy --trust $env.IDR_ROLE_TEMPLATE nix/role ...$copier_args -d $"name=($role_name)"
}

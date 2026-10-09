# Render literal user input in generated Nix source, without enabling interpolation.
export def nix-string [value: string] {
  let escaped = $value
    | str replace --all '\' '\\'
    | str replace --all '"' '\"'
    | str replace --all '${' '\${'
    | str replace --all "\n" '\n'
    | str replace --all "\r" '\r'
    | str replace --all "\t" '\t'

  '"' + $escaped + '"'
}

export def nix-identifier [value: string] {
  let keywords = ["if" "then" "else" "assert" "with" "let" "in" "rec" "inherit"]
  if $value =~ "^[a-zA-Z_][a-zA-Z0-9_'-]*$" and $value not-in $keywords {
    $value
  } else {
    nix-string $value
  }
}

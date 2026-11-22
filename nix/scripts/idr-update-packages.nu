# Update packages declared in idr.packages with their update scripts.
def main [
  --threads (-t): int # Packages updated at once; the number of CPU threads when omitted
  ...names: string # Packages to update; all declared packages when omitted
] {
  cd ($env.PRJ_ROOT? | default $env.PWD)
  let packages = open $env.IDR_PACKAGES_FILE
  let declared = $packages | columns
  let unknown = $names | where {|name| $name not-in $declared }
  if ($unknown | is-not-empty) {
    error make --unspanned {msg: $"Unknown packages: ($unknown | str join ', ')"}
  }
  let threads = $threads | default (sys cpu | length)
  if $threads < 1 {
    error make --unspanned {msg: "--threads must be at least 1"}
  }

  # Each package's output is printed in one piece when it finishes.
  let update = {|name|
    let package = $packages | get $name
    print $"Updating ($name)"
    mut result = do { ^$package.update } o+e>| complete
    # Packages unavailable on this system are only updated.
    if $result.exit_code == 0 and $package.build {
      let built = do { ^nix build --no-link --print-build-logs $".#($name)" } o+e>| complete
      $result = {stdout: ($result.stdout + $built.stdout) exit_code: $built.exit_code}
    }
    let status = if $result.exit_code == 0 { "updated" } else { "failed" }
    print $"── ($name): ($status)\n($result.stdout)"
    {name: $name failed: ($result.exit_code != 0)}
  }

  let selected = if ($names | is-empty) { $declared } else { $names | uniq }
  let results = $selected | par-each --threads $threads $update
  let failed = $results | where {|result| $result.failed } | get name | sort
  if ($failed | is-not-empty) {
    error make --unspanned {msg: $"Could not update: ($failed | str join ', ')"}
  }
}

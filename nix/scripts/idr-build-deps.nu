const script_path = path self

use idr-common.nu [host-data-dir]

def main [
  --locked
  source: string
  system: string
  ...names: string
] {
  let directory = if ($env.IDR_GCROOT? | default "") == "" {
    host-data-dir | path join "gcroot" | path expand
  } else {
    $env.IDR_GCROOT | path expand
  }
  mkdir $directory

  if not $locked {
    exec flock --close ($directory | path join ".build.lock") $nu.current-exe -n --no-std-lib --no-history $script_path --locked $source $system ...$names
  }

  # A pinned NAR hash enables the flake evaluation cache for this store path.
  let hash = nix hash path $source | complete
  if $hash.exit_code != 0 {
    print -e $hash.stderr
    exit $hash.exit_code
  }
  let reference = $"path:($source)?narHash=($hash.stdout | str trim | url encode)"

  let results = $names | par-each {|name|
    let installable = $"($reference)#packages.($system).default.passthru.deps.($name)"
    nix build --no-write-lock-file --out-link ($directory | path join $name) $installable
    {name: $name, exit_code: $env.LAST_EXIT_CODE}
  } | collect
  let failed = $results | where exit_code != 0
  if not ($failed | is-empty) {
    exit ($failed | first | get exit_code)
  }
}

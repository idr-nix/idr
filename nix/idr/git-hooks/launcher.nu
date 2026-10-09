# Portable hook health checks and regeneration. The generated /bin/sh entry
# point only bootstraps Nushell when this host's interpreter is unavailable.
def --wrapped main [hook: string, ...args: string] {
  let manifest = '@manifest@' | from json
  let payload = $hook | path expand | path dirname | path join $manifest.payload
  let executable = try {
    (^test -x $payload | complete | get exit_code) == 0
  } catch { false }
  let healthy = ((^uname -sm | str trim) == $manifest.platform
    and $executable
    and ($manifest.config | path exists)
    and ($manifest.closure | all {|path| $path | path exists }))

  if $healthy {
    hide-env -i IDR_GIT_HOOK_REPAIR
    exec $payload ...$args
  }
  if ($env.IDR_GIT_HOOK_REPAIR? | default '') == '1' {
    print -e 'idr: Git hook dependencies are still unavailable after shell regeneration.'
    exit 1
  }
  print -e 'idr: regenerating Git hooks for this host.'
  $env.IDR_GIT_HOOK_REPAIR = '1'
  # Shell startup must not consume a pre-push hook's inherited standard input.
  # The installer takes the project lock; do not acquire it around regeneration.
  '' | ^nix develop -c true out+err> /dev/stderr
  exec $hook ...$args
}

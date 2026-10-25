const script_path = path self

def read-state [path: string] {
  if ($path | path exists) { open --raw $path | str trim } else { "" }
}

def write-state [path: string value: string] {
  let temporary = $"($path).tmp"
  $value | save --force $temporary
  mv --force $temporary $path
}

def paths [kind: string] {
  if $kind == "" or ($kind | path basename) != $kind or $kind in ["." ".."] {
    error make {msg: $"Invalid background build name: ($kind)"}
  }
  let root = $env.IDR_GCROOT | path expand --no-symlink
  let state = $root | path dirname | path join "builds" $kind
  mkdir $root $state
  {state: $state output: ($root | path join $kind)}
}

def --wrapped checked [command: string ...arguments: string] {
  let result = run-external $command ...$arguments | complete
  if $result.exit_code != 0 {
    error make {msg: $"($command) failed: ($result.stderr | str trim)"}
  }
  $result.stdout | str trim
}

def locked [state: string action: string ...arguments: string] {
  checked flock --close ($state | path join "control.lock") $nu.current-exe -n --no-std-lib --no-history $script_path $action ...$arguments
}

def available [state: string] {
  let result = ^flock --nonblock ($state | path join "worker.lock") true | complete
  if $result.exit_code not-in [0 1] {
    error make {msg: $result.stderr}
  }
  $result.exit_code == 0
}

def root [path: string target: string] {
  checked nix-store --add-root $path --indirect --realise $target | ignore
}

def usable [state: string output: string] {
  let target = read-state ($state | path join "target")
  $target != "" and ($output | path exists) and ($output | path expand) == $target
}

def restore [state: string output: string request: string] {
  let target = read-state ($state | path join "target")
  if (read-state ($state | path join "completed")) == $request and $target != "" and ($target | path exists) {
    root $output $target
    true
  } else {
    false
  }
}

def spawn [state: string kind: string] {
  write-state ($state | path join "pid") ""
  if (read-state ($state | path join "completed")) == (read-state ($state | path join "request")) {
    rm --force ($state | path join "completed")
  }
  let log = $state | path join "build.log"
  let environment = which env | first | get path
  let close_descriptors = ls /dev/fd | get name | path basename | into int | where {|descriptor| $descriptor > 2 } | each {|descriptor| [fdclose ($descriptor | into string)] } | flatten
  let command = $close_descriptors ++ [daemonize -a -l ($state | path join "worker.lock") -o $log -e $log -c $env.PRJ_ROOT $environment --ignore-signal=TERM $nu.current-exe -n --no-std-lib --no-history $script_path _worker $kind]
  checked ($command | first) ...($command | skip 1) | ignore
}

def cancel [state: string] {
  if (available $state) { return true }
  let group = read-state ($state | path join "pid")
  if $group == "" { return false }
  for signal in [TERM KILL] {
    if (available $state) { return true }
    ^kill $"-($signal)" -- $"-($group)" | complete | ignore
    for _ in 1..25 {
      if (available $state) { return true }
      sleep 10ms
    }
  }
  error make {msg: $"Could not stop the previous build; see ($state | path join 'build.log')"}
}

def start [kind: string] {
  let paths = paths $kind
  let state = $paths.state
  let job = open $env.IDR_BACKGROUND_BUILDS | get $kind
  let request = $job | transpose key value | sort-by key | reduce --fold {} {|item, result| $result | insert $item.key $item.value } | to json --raw
  let previous = read-state ($state | path join "request")
  root ($state | path join "source") $job.source
  write-state ($state | path join "request") $request
  rm --force ($state | path join "error")
  if not (available $state) {
    if $previous == $request or not (cancel $state) { return }
  }
  if (restore $state $paths.output $request) {
    if not ($job.generateDocs? | default false) or ($env.PRJ_ROOT | path join "docs/generated" | path type) == "dir" { return }
  }
  spawn $state $kind
}

def disable [kind: string] {
  let state = (paths $kind).state
  write-state ($state | path join "request") ""
  cancel $state | ignore
}

def publish [kind: string request: string] {
  let paths = paths $kind
  let state = $paths.state
  if (read-state ($state | path join "request")) != $request { return }
  let result = $state | path join "result"
  let target = $result | path expand
  root $paths.output $target
  let generated = $state | path join "generated"
  if ($generated | path join "docs/generated" | path exists) {
    let destination = $env.PRJ_ROOT | path join "docs/generated"
    mkdir $destination
    let temporary = checked mktemp -d ($destination | path join ".idr-generated.XXXXXX")
    try {
      for path in (ls --all ($generated | path join "docs/generated") | get name) {
        let staged = $temporary | path join ($path | path basename)
        cp $path $staged
        mv --force $staged ($destination | path join ($path | path basename))
      }
    } catch {|error|
      rm --recursive --force $temporary
      error make $error
    }
    rm --recursive --force $temporary $generated
  }
  write-state ($state | path join "target") $target
  write-state ($state | path join "completed") $request
  rm --force ($state | path join "error") $result
}

def --env worker [kind: string] {
  let state = (paths $kind).state
  $env.NIX_CACHE_HOME = $state | path join "nix-cache"
  let group = checked ps -o pgid= -p ($nu.pid | into string)
  let request = locked $state _register $kind $group
  if $request == "" { return }
  try {
    let job = $request | from json
    print $"Building ($kind) from ($job.source)"
    let digest = checked env --default-signal=TERM nix hash path $job.source
    let reference = $"path:($job.source)?narHash=($digest | url encode)"
    let result = $state | path join "result"
    ^env --default-signal=TERM nix build --no-write-lock-file --out-link $result $"($reference)#($job.attribute)"
    if $env.LAST_EXIT_CODE != 0 { error make {msg: $"($kind) build failed"} }
    let generated = $state | path join "generated"
    rm --recursive --force $generated
    let writable = ^test -w $env.PRJ_ROOT | complete
    if ($job.generateDocs? | default false) and $writable.exit_code == 0 {
      mkdir $generated
      cd $generated
      ^env --default-signal=TERM ($result | path join "bin/idr-generate-docs")
      if $env.LAST_EXIT_CODE != 0 { error make {msg: "Documentation generation failed"} }
      cd $env.PRJ_ROOT
    }
    locked $state _publish $kind $request | ignore
  } catch {|error|
    print --stderr $"($kind): ($error.msg)"
    locked $state _error $kind $request | ignore
    exit 1
  }
}

def status [kind: string previous: bool] {
  let paths = paths $kind
  let state = $paths.state
  let request = read-state ($state | path join "request")
  if $request == "" { error make {msg: $"($kind) is disabled in the current shell"} }
  if (usable $state $paths.output) and ($previous or (read-state ($state | path join "completed")) == $request) { return "ready" }
  if (restore $state $paths.output $request) { return "ready" }
  if (read-state ($state | path join "error")) == $request {
    error make {msg: $"($kind) build failed; see ($state | path join 'build.log')"}
  }
  if (available $state) { spawn $state $kind }
  "pending"
}

def wait-for [kind: string --previous] {
  let state = (paths $kind).state
  if not ($state | path join "request" | path exists) { locked $state _start $kind | ignore }
  loop {
    if (locked $state _status $kind (if $previous { "previous" } else { "current" })) == "ready" { return }
    sleep 100ms
  }
}

def main [action: string ...arguments: string] {
  let state = $env.IDR_GCROOT | path expand --no-symlink | path dirname | path join "builds"
  mkdir $state
  match $action {
    start => { exec flock --close ($state | path join "control.lock") $nu.current-exe -n --no-std-lib --no-history $script_path _start-all }
    _start-all => {
      let jobs = open $env.IDR_BACKGROUND_BUILDS | columns
      for path in (ls --all $state | get name) {
        let kind = $path | path basename
        if ($path | path type) == "dir" and ($path | path join "request" | path exists) and $kind not-in $jobs {
          locked $path _disable $kind | ignore
        }
      }
      $jobs | par-each {|kind| locked (paths $kind).state _start $kind } | collect | ignore
    }
    _start => { start $arguments.0 }
    _disable => { disable $arguments.0 }
    _worker => { worker $arguments.0 }
    _register => {
      let directory = (paths $arguments.0).state
      write-state ($directory | path join "pid") $arguments.1
      read-state ($directory | path join "request")
    }
    _publish => { publish $arguments.0 $arguments.1 }
    _error => {
      let directory = (paths $arguments.0).state
      if (read-state ($directory | path join "request")) == $arguments.1 {
        write-state ($directory | path join "error") $arguments.1
      }
    }
    _status => { status $arguments.0 ($arguments.1 == "previous") }
    ready => { wait-for $arguments.0 --previous }
    wait => {
      let jobs = if ($arguments | is-empty) { open $env.IDR_BACKGROUND_BUILDS | columns } else { $arguments }
      for kind in $jobs { wait-for $kind }
    }
    generate => {
      loop {
        wait-for documentation
        if (locked (paths documentation).state _generate) == "done" { return }
      }
    }
    _generate => {
      let paths = paths documentation
      if (usable $paths.state $paths.output) and (read-state ($paths.state | path join "completed")) == (read-state ($paths.state | path join "request")) {
        cd $env.PRJ_ROOT
        checked env --default-signal=TERM ($paths.output | path join "bin/idr-generate-docs") | ignore
        "done"
      }
    }
    _ => { error make {msg: $"Unknown background build action: ($action)"} }
  }
}

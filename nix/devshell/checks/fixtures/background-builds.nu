const script = path self
const packages = {
  documentation: "idr-generate-docs"
  search-options: "idr-nix-search-tv-config"
  example-machine: "default.passthru.deps.example-machine"
}
const kinds = [documentation search-options]

def ensure [condition: bool message: string] {
  if not $condition { error make {msg: $message} }
}

def wait-for [predicate: closure message: string timeout: duration = 10sec] {
  let deadline = (date now) + $timeout
  while not (do $predicate) {
    ensure ((date now) < $deadline) $message
    sleep 20ms
  }
}

def marker [project: record generation: string kind: string suffix: string] {
  $project.barriers | path join $"($generation)-($kind).($suffix)"
}

def replace-link [path: string target: string] {
  mkdir ($path | path dirname)
  let temporary = $"($path).($nu.pid)"
  ^ln -s $target $temporary
  ^mv -Tf $temporary $path
}

def alive [pid: int] {
  not (ps | where pid == $pid | where status not-in [Zombie Dead] | is-empty)
}

def process-group [] {
  ^ps -o pgid= -p $nu.pid | str trim | into int
}

def --wrapped "main fake" [tool: string ...arguments: string] {
  if $tool == "nix-store" {
    ensure ("--add-root" in $arguments and "--realise" in $arguments) $"Unexpected nix-store arguments: ($arguments)"
    let source = $arguments | last
    if ($source | path dirname | path basename) == "sources" {
      let barrier = $env.TEST_BARRIERS | path join $"($source | path basename)-pin"
      touch $"($barrier).started"
      if ($"($barrier).pause" | path exists) {
        wait-for { $"($barrier).release" | path exists } "source pin was not released"
      }
    }
    let index = $arguments | enumerate | where item == "--add-root" | first | get index
    replace-link ($arguments | get ($index + 1)) $source
    print $source
    return
  }
  if ($arguments | first 2) == [hash path] {
    print "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    return
  }
  ensure (($arguments | first) == "build") $"Unexpected nix arguments: ($arguments)"
  let installable = $arguments | where { str contains "#packages." } | first | split row "#"
  let generation = $installable.0 | str replace --regex '^path:' '' | split row '?' | first | url decode | path basename
  let kind = $packages | transpose name attribute | where {|entry| $installable.1 | str ends-with $".($entry.attribute)" } | first | get name
  let barrier = $env.TEST_BARRIERS | path join $"($generation)-($kind)"
  $nu.pid | into string | save -f $"($barrier).pid"
  process-group | into string | save -f $"($barrier).group"
  $env.NIX_CACHE_HOME | save -f $"($barrier).cache-home"
  if ($"($barrier).spawn-child" | path exists) {
    ^$nu.current-exe -n --no-std-lib --no-history $script child $barrier
  }
  touch $"($barrier).started"
  wait-for { $"($barrier).release" | path exists } $"unreleased build: ($barrier)"
  if ($"($barrier).fail" | path exists) {
    print -e $"deliberate build failure: ($generation)/($kind)"
    exit 1
  }
  let output = $env.TEST_OUTPUTS | path join $generation $kind
  mkdir ($output | path join bin)
  let generator = $output | path join bin idr-generate-docs
  [
    $"#!($nu.current-exe) -n"
    "mkdir docs/generated"
    $"($generation | to nuon) | save -f docs/generated/generation"
  ] | str join "\n" | save -f $generator
  ^chmod +x $generator
  let index = $arguments | enumerate | where item == "--out-link" | first | get index
  replace-link ($arguments | get ($index + 1)) $output
  print $output
}

def "main child" [barrier: string] {
  $nu.pid | into string | save -f $"($barrier).child-pid"
  touch $"($barrier).started"
  loop { sleep 1sec }
}

def project [directory: string manager: string] {
  let result = {
    directory: $directory
    manager: $manager
    roots: ($directory | path join .data host gcroot)
    barriers: ($directory | path join barriers)
    outputs: ($directory | path join outputs)
    generated: ($directory | path join docs generated generation)
  }
  mkdir $result.barriers
  $result
}

def command [project: record generation: string arguments: list<string> --sources: record --fd3] {
  let names = if $arguments.0 == "start" {
    $arguments | skip 1
  } else if $sources != null {
    $sources | columns
  } else { $kinds }
  mut jobs = {}
  for name in $names {
    let source = $project.directory | path join sources ($sources | default {} | get -o $name | default $generation)
    mkdir $source
    $jobs = $jobs | insert $name {
      source: $source
      attribute: $"packages.test-system.($packages | get $name)"
      generateDocs: ($name == "documentation")
    }
  }
  let config = mktemp -p $project.directory "request.XXXXXX.json"
  $jobs | to json | save -f $config
  let environment = {
    PRJ_ROOT: $project.directory
    IDR_GCROOT: $project.roots
    TEST_BARRIERS: $project.barriers
    TEST_OUTPUTS: $project.outputs
    IDR_BACKGROUND_BUILDS: $config
  }
  let arguments = if $arguments.0 == "start" { [start] } else { $arguments }
  let invocation = [$nu.current-exe -n --no-std-lib --no-history $project.manager ...$arguments]
  let invocation = if $fd3 { [fdmove -c "3" "1" ...$invocation] } else { $invocation }
  let result = $"($config).result"
  let job = job spawn {
    with-env $environment {
      cd $project.directory
      run-external ($invocation | first) ...($invocation | skip 1) | complete | to json | save -f $"($result).tmp"
      mv $"($result).tmp" $result
    }
  }
  {job: $job result: $result}
}

def finish [process: record --failure] {
  wait-for { $process.result | path exists } $"command did not finish: ($process.result)"
  let result = open --raw $process.result | from json
  ensure (($result.exit_code == 0) != $failure) $"Unexpected result: ($result | to nuon)"
}

def run [project: record generation: string arguments: list<string> --sources: record] {
  let process = command $project $generation $arguments --sources $sources
  finish $process
}

def pending [process: record] {
  sleep 100ms
  ensure (not ($process.result | path exists)) $"command did not wait: ($process.result)"
}

def started [project: record generation: string names: list<string>] {
  for kind in $names {
    let path = marker $project $generation $kind started
    wait-for { $path | path exists } $"build did not start: ($path)"
  }
}

def release [project: record generation: string names: list<string> --failure] {
  for kind in $names {
    if $failure { touch (marker $project $generation $kind fail) }
    touch (marker $project $generation $kind release)
  }
}

def root-is [project: record generation: string kind: string] {
  ($project.roots | path join $kind | path expand) == ($project.outputs | path join $generation $kind)
}

def published [project: record generation: string names: list<string>] {
  for kind in $names {
    wait-for { root-is $project $generation $kind } $"missing root: ($generation)/($kind)"
  }
}

def stopped [project: record generation: string kind: string suffix: string] {
  let pid = open --raw (marker $project $generation $kind $suffix) | into int
  wait-for { not (alive $pid) } $"obsolete process still running: ($pid)"
}

def check-generation [project: record expected: string] {
  ensure ((open --raw $project.generated | str trim) == $expected) $"wrong generated documentation: ($expected)"
}

def scenarios [directory: string manager: string] {
  let project = project ($directory | path join project) $manager
  let startup = command $project first [start ...$kinds] --fd3
  wait-for { $startup.result | path exists } "background workers kept the inherited output pipe open" 2sec
  finish $startup
  started $project first $kinds
  let caches = $kinds | each {|kind| open --raw (marker $project first $kind cache-home) }
  ensure (($caches | uniq | length) == ($kinds | length)) "parallel jobs share their evaluation cache"
  let generation = command $project first [generate]
  let search = command $project first [ready search-options]
  pending $generation
  pending $search
  release $project first $kinds
  finish $generation
  finish $search
  published $project first $kinds
  check-generation $project first
  print "nonblocking entry, parallel builds, and first-use waits passed"

  let targets = $kinds | each {|kind| $project.roots | path join $kind | path expand }
  rm ($project.roots | path join search-options) ($project.roots | path join documentation)
  ^ln -s $targets.1 ($project.roots | path join documentation)
  run $project first [start ...$kinds]
  ensure (($kinds | each {|kind| $project.roots | path join $kind | path expand }) == $targets) "start did not repair roots"
  rm ($project.roots | path join search-options)
  run $project first [wait search-options]
  ensure (($project.roots | path join search-options | path expand) == $targets.1) "wait did not repair its root"
  print "same-source reloads restore missing and incorrect roots"

  run $project second [start ...$kinds]
  started $project second $kinds
  ensure (($kinds | each {|kind| open --raw (marker $project second $kind cache-home) }) == $caches) "project changes replaced cache directories"
  ensure ($kinds | all {|kind| root-is $project first $kind }) "old roots disappeared during rebuild"
  run $project second [ready search-options]
  let generation = command $project second [generate]
  pending $generation
  release $project second $kinds
  finish $generation
  published $project second $kinds
  check-generation $project second
  print "previous outputs remain available until replacements succeed"

  run $project failed [start documentation]
  started $project failed [documentation]
  let generation = command $project failed [generate]
  pending $generation
  release $project failed [documentation] --failure
  finish $generation --failure
  ensure (root-is $project second documentation) "failed build replaced the previous root"
  check-generation $project second

  let empty = project ($directory | path join "failed first use") $manager
  run $empty failed [start search-options]
  started $empty failed [search-options]
  let search = command $empty failed [ready search-options]
  pending $search
  release $empty failed [search-options] --failure
  finish $search --failure
  ensure (not ($empty.roots | path join search-options | path exists)) "failed build published a root"
  rm (marker $empty failed search-options fail)
  run $empty failed [start search-options]
  run $empty failed [ready search-options]
  published $empty failed [search-options]
  print "build failures preserve old results and unblock first use with an error"

  for kind in $kinds { touch (marker $project stale $kind spawn-child) }
  run $project stale [start ...$kinds]
  started $project stale $kinds
  let generation = command $project stale [generate]
  pending $generation
  run $project latest [start ...$kinds]
  started $project latest $kinds
  for kind in $kinds {
    stopped $project stale $kind pid
    stopped $project stale $kind child-pid
  }
  ensure ($kinds | all {|kind| root-is $project second $kind }) "obsolete builds replaced roots"
  check-generation $project second
  release $project latest $kinds
  finish $generation
  published $project latest $kinds
  run $project latest [generate]
  check-generation $project latest
  print "overlapping reloads terminate obsolete process groups and publish the latest source"

  run $project disabled [start ...$kinds]
  started $project disabled $kinds
  let generation = command $project disabled [generate]
  pending $generation
  run $project disabled [start]
  finish $generation --failure
  for kind in $kinds {
    stopped $project disabled $kind pid
    ensure (root-is $project latest $kind) "disabling removed the previous root"
  }
  check-generation $project latest
  print "disabling documentation stops builds and unblocks waiting commands"

  let concurrent = project ($directory | path join "concurrent registration") $manager
  touch ($concurrent.barriers | path join batch-old-pin.pause)
  let older = command $concurrent batch-old [start ...$kinds]
  wait-for { $concurrent.barriers | path join batch-old-pin.started | path exists } "older registration did not start"
  let newer = command $concurrent batch-new [start ...($kinds | reverse)]
  pending $newer
  ensure (not ($concurrent.barriers | path join batch-new-pin.started | path exists)) "source batches interleaved"
  touch ($concurrent.barriers | path join batch-old-pin.release)
  finish $older
  finish $newer
  started $concurrent batch-new $kinds
  release $concurrent batch-new $kinds
  published $concurrent batch-new $kinds
  run $concurrent batch-new [generate]
  check-generation $concurrent batch-new
  print "concurrent reloads register complete source batches"

  let interrupted = project ($directory | path join "interrupted worker") $manager
  run $interrupted restart [start documentation]
  started $interrupted restart [documentation]
  let group = open --raw (marker $interrupted restart documentation group) | into int
  ensure ($group != (process-group)) "worker shares the test runner's process group"
  ^kill -KILL -- $"-($group)"
  release $interrupted restart [documentation]
  run $interrupted restart [start documentation]
  run $interrupted restart [generate]
  published $interrupted restart [documentation]
  check-generation $interrupted restart
  print "an abruptly killed worker does not leave a stale lock"

  let dependencies = project ($directory | path join "stable dependency") $manager
  let dependency_kinds = [documentation example-machine]
  mut sources = {documentation: old-project example-machine: fixed-input}
  run $dependencies old-project [start ...$dependency_kinds] --sources $sources
  started $dependencies old-project [documentation]
  started $dependencies fixed-input [example-machine]
  let group = open --raw (marker $dependencies fixed-input example-machine group)
  $sources.documentation = "new-project"
  run $dependencies new-project [start ...$dependency_kinds] --sources $sources
  started $dependencies new-project [documentation]
  ensure (alive (open --raw (marker $dependencies fixed-input example-machine pid) | into int)) "project change stopped an unchanged dependency"
  release $dependencies new-project [documentation]
  release $dependencies fixed-input [example-machine]
  run $dependencies new-project [wait] --sources $sources
  published $dependencies fixed-input [example-machine]
  $sources.documentation = "newer-project"
  run $dependencies newer-project [start ...$dependency_kinds] --sources $sources
  started $dependencies newer-project [documentation]
  release $dependencies newer-project [documentation]
  run $dependencies newer-project [wait] --sources $sources
  ensure ((open --raw (marker $dependencies fixed-input example-machine group)) == $group) "project change rebuilt a completed dependency"
  check-generation $dependencies newer-project
  print "fixed-source dependencies survive project changes without cancellation or rebuilding"
}

def main [manager: string] {
  let directory = mktemp -d -t "background builds.XXXXXX"
  let binaries = $directory | path join bin
  mkdir $binaries
  for name in [nix nix-store] {
    let wrapper = $binaries | path join $name
    [
      $"#!($nu.current-exe) -n"
      "def --wrapped main [...arguments: string] {"
      $"  exec ($nu.current-exe | to nuon) -n --no-std-lib --no-history ($script | to nuon) fake ($name) ...$arguments"
      "}"
    ] | str join "\n" | save -f $wrapper
    ^chmod +x $wrapper
  }
  with-env {PATH: ([$binaries] ++ $env.PATH)} {
    try { scenarios $directory ($manager | path expand) } catch {|error|
      print -e $"Test files retained at ($directory)"
      error make $error
    }
  }
  rm -rf $directory
}

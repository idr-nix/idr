# Runs Envoy for a service, applying changes without stopping it.
#
# DIRECTORY holds envoy.json, the bootstrap; validate.json, the same
# configuration with every resource inlined; command, Envoy's executable and
# arguments, one per line; secrets, a line of "<source path> <name> <static or
# dynamic>" for each secret; and xds, the dynamic resources, one file each.
#
# In $RUNTIME_DIRECTORY, owned by Envoy's user, staged holds the secrets to
# validate; envoy.json, command, secrets and xds what Envoy reads, once valid;
# and requested the fingerprint of the last valid configuration.

def main [] {
  help main
}

def command [directory: path] {
  open --raw ($directory | path join command) | lines
}

def listed [directory: path] {
  open --raw ($directory | path join secrets) | lines | parse "{source} {name} {kind}"
}

def files [directory: path] {
  if ($directory | path exists) { ls $directory | each {|file| $file.name } } else { [] }
}

# What a running Envoy cannot apply without starting anew.
def fingerprint [directory: path] {
  let runtime = $env.RUNTIME_DIRECTORY
  let statics = listed $directory | where kind == static | each {|secret|
    $runtime | path join secrets $secret.name
  }
  [($runtime | path join envoy.json) ($runtime | path join command) ...$statics]
  | each {|file| open --raw $file | hash sha256 }
  | str join
  | hash sha256
}

# Replaces a file only when it changed, by a move, which Envoy watches for.
def replace [source: path, target: path] {
  if ($target | path exists) and ((open --raw $source) == (open --raw $target)) {
    return
  }
  let temporary = $target | path dirname | path join .new
  rm --force $temporary
  cp $source $temporary
  mv --force $temporary $target
}

# Starts an Envoy, which reports its exit status. Programs in a job have no
# standard output, so Envoy logs to the journal itself.
def launch [base: int, epoch: int] {
  let envoy = command $env.RUNTIME_DIRECTORY
  let config = $env.RUNTIME_DIRECTORY | path join envoy.json
  job spawn {
    let status = try {
      ^systemd-cat --identifier=envoy ...$envoy --config-path $config --base-id $base --restart-epoch $epoch
      0
    } catch {|error| $error.exit_code? | default 1 }
    {epoch: $epoch, status: $status} | job send 0
  }
}

# Starts Envoy, and a new Envoy for each configuration that reload requests:
# it takes over the listeners while the previous one drains its connections
# and exits.
def "main run" [directory: path, base: int] {
  let requested = $env.RUNTIME_DIRECTORY | path join requested
  mut wanted = fingerprint $directory
  # The newest Envoy's configuration, when it is started.
  mut current = null
  mut epoch = 0
  # Start times of the running Envoys, by restart epoch.
  mut running = {}
  mut since = (date now) - 1day
  mut attempts = 0
  loop {
    # One Envoy starts at a time, and settles before the next.
    if $wanted != $current and ((date now) - $since) >= 2sec {
      launch $base $epoch
      $running = $running | upsert ($epoch | into string) (date now)
      $current = $wanted
      $epoch += 1
      $since = date now
    }
    let message = try { job recv --timeout 1sec } catch { null }
    if $message != null {
      let key = $message.epoch | into string
      let age = (date now) - ($running | get --optional $key | default (date now))
      $running = $running | reject --optional $key
      if $message.status != 0 {
        # Envoy refuses to start while the previous one is initializing. The
        # older ones still serve, so try the same epoch again.
        if $message.epoch > 0 and $message.epoch == $epoch - 1 and $age < 5sec and ($running | is-not-empty) and $attempts < 30 {
          $attempts += 1
          $epoch = $message.epoch
          $current = null
          $since = (date now) - 1sec
        } else {
          # Start afresh: the service manager restarts this service.
          print --stderr $"Envoy of restart epoch ($message.epoch) failed with status ($message.status); stopping"
          exit 1
        }
      } else if ($running | is-empty) {
        exit 0
      }
    }
    if ($requested | path exists) {
      let request = open --raw $requested
      if $request != $wanted {
        $wanted = $request
        $attempts = 0
      }
    }
  }
}

# As root, reads the listed secrets for stage, which writes them as Envoy's
# user: root writes nothing in a directory that user owns.
def "main secrets" [directory: path] {
  let owner = ^stat --format=%u:%g $env.RUNTIME_DIRECTORY | str trim | split row ":"
  listed $directory
  | each {|secret| {name: $secret.name, content: (open --raw $secret.source | encode base64)} }
  | to json --raw
  | ^setpriv --reuid ($owner | first) --regid ($owner | last) --clear-groups $nu.current-exe --no-config-file --stdin $env.CURRENT_FILE stage
}

# Stages the secrets on input for validation; install puts them in place.
def "main stage" [] {
  let secrets = $in | from json
  let staged = $env.RUNTIME_DIRECTORY | path join staged
  mkdir $staged
  for secret in $secrets {
    let temporary = $staged | path join $".($secret.name)"
    rm --force $temporary
    $secret.content | decode base64 | save $temporary
    ^chmod 0400 $temporary
    mv --force $temporary ($staged | path join $secret.name)
  }
  let names = $secrets | each {|secret| $secret.name }
  for file in (files $staged) {
    if ($file | path basename) not-in $names {
      rm --force $file
    }
  }
}

# Installs the staged secrets and the dynamic resources, which Envoy watches,
# and the bootstrap and command that a new Envoy starts with. Envoy loads
# resources only after those they refer to: secrets, route tables and clusters
# before listeners. Removed files go last.
def "main install" [directory: path] {
  let runtime = $env.RUNTIME_DIRECTORY
  let staged = $runtime | path join staged
  let secrets = $runtime | path join secrets
  let xds = $runtime | path join xds
  mkdir $secrets ($xds | path join secrets) ($xds | path join routes)
  for file in (files $staged) {
    replace $file ($secrets | path join ($file | path basename))
  }
  for kind in [secrets routes] {
    for file in (files ($directory | path join xds $kind)) {
      replace $file ($xds | path join $kind ($file | path basename))
    }
  }
  for resource in [cds.json lds.json] {
    replace ($directory | path join xds $resource) ($xds | path join $resource)
  }
  for kind in [secrets routes] {
    for file in (files ($xds | path join $kind)) {
      if not ($directory | path join xds $kind ($file | path basename) | path exists) {
        rm --force $file
      }
    }
  }
  for file in (files $secrets) {
    if not ($staged | path join ($file | path basename) | path exists) {
      rm --force $file
    }
  }
  for file in [envoy.json command] {
    replace ($directory | path join $file) ($runtime | path join $file)
  }
}

# Validates the configuration with the staged secrets and installs it. When
# Envoy cannot apply it, run starts a new Envoy.
def "main reload" [directory: path] {
  let envoy = command $directory
  let program = $envoy | first
  ^$program ...($envoy | skip 1) --config-path ($directory | path join validate.json) --mode validate
  main install $directory
  let requested = $env.RUNTIME_DIRECTORY | path join requested
  fingerprint $directory | save --force $"($requested).new"
  mv --force $"($requested).new" $requested
}

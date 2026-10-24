# Exercise the installer command and adapter without accessing real target disks.
const fixture_file = path self

def check [condition: bool, message: string] {
  if not $condition {
    error make {msg: $message}
  }
}

def option-values [arguments: list<string>, option: string] {
  $arguments | enumerate | where item == $option | each {|entry|
    $arguments | get ($entry.index + 1)
  }
}

# Record and answer the external transport boundary of the real Nushell script.
def --wrapped "main external" [name: string, ...arguments: string] {
  [$name ...$arguments] | to json --raw | $"($in)\n" | save --append $env.CALLS
  match $name {
    "nix" => {
      if ($arguments | first) == "eval" {
        print (open --raw $env.TARGET)
      } else if ($arguments | first 2) == [flake lock] {
        "{}" | save --force (option-values $arguments "--output-lock-file" | first)
      } else {
        error make {msg: $"Unexpected nix arguments: ($arguments | to nuon)"}
      }
    }
    "ssh" => {
      if "-G" in $arguments {
        print "host rescue\nhostname 127.0.0.1\nuser root\nport 2223"
      } else {
        # The inspector shell-quotes every word; only its executable is needed here.
        let command = $arguments | last | split row " " | first | str trim --char "'"
        match $command {
          "cat" => { print "ID=nixos" }
          "swapon" => {}
          "lsblk" => {
            let devices = if ($env.MISSING_DISK? | default "") != "" {
              []
            } else {
              [{
                name: "/dev/installation-test", "maj:min": "8:0", type: "disk",
                fstype: "ext4", mountpoints: ["/mnt"]
              }]
            }
            print ({blockdevices: $devices} | to json --raw)
          }
          _ => { error make {msg: $"Unexpected inspection command: ($command)"} }
        }
      }
    }
    "nixos-anywhere" => {
      let directory = $env.TMPDIR | path join "installation"
      {
        args: $arguments,
        target: (open ($directory | path join "target.json"))
      } | to json | save --force $env.INSTALLATION
      exit ($env.INSTALL_STATUS? | default "0" | into int)
    }
    "git" => {}
    _ => { error make {msg: $"Unexpected external command: ($name)"} }
  }
}

def adapter [script: string, expected: list<string>, --fails, --overrides: record = {}] {
  let operations = $env.TEST_WORK | path join "operations"
  if ($operations | path exists) { rm $operations }
  let executable = open $env.SCRIPT_PATHS | get $script
  let result = with-env ({OPERATIONS: $operations} | merge $overrides) {
    ^$executable | complete
  }
  let output = $result.stdout + $result.stderr
  check (($result.exit_code == 0) != $fails) $output
  check ((open --raw $operations | lines) == $expected) $"Unexpected disk operations: ($output)"
}

def cli [options: list<string>, --error: string, --overrides: record = {}] {
  for file in [$env.CALLS $env.INSTALLATION] {
    if ($file | path exists) { rm $file }
  }
  let result = with-env $overrides {
    "" | ^nu --no-config-file --no-std-lib --no-history (
      $env.SCRIPT_SOURCE | path join "idr-anywhere.nu"
    ) test-machine -n ...$options | complete
  }
  let output = $result.stdout + $result.stderr
  let captured = if $error == null {
    check ($result.exit_code == 0) $output
    open $env.INSTALLATION
  } else {
    check ($result.exit_code != 0 and ($output | str contains $error)) $output
    null
  }
  check (glob ($env.PRJ_DATA_DIR | path join "idr-disko-files-*") | is-empty) "Temporary installation files leaked"
  $captured
}

def main [] {
  $env.TEST_WORK = $env.PWD

  # Both upstream nixos-anywhere execution paths must use only disko's mount action.
  adapter mountScript [mount]
  adapter mountScriptNoDeps [mountNoDeps]
  adapter mountScript [mount] --fails --overrides {mount_STATUS: "7"}
  adapter mountScriptNoDeps [mountNoDeps] --fails --overrides {mountNoDeps_STATUS: "7"}
  # Retain the default installation's best-effort format and ordinary-failure fallback.
  adapter diskoScript [format]
  adapter diskoScript [format wipe] --overrides {format_STATUS: "7"}
  adapter diskoScript [format] --fails --overrides {format_STATUS: "130"}

  let project = $env.TEST_WORK | path join "project"
  let data = $project | path join ".data"
  let machine = $project | path join "nix/machine/test-machine"
  mkdir $machine $data
  "{}" | save ($machine | path join "configuration.nix")
  let target = $env.TEST_WORK | path join "target.json"
  {
    hostname: rescue, sshUser: root, sshOpts: [], fastConnection: false,
    preFormatFiles: {}, postFormatFiles: {}, hostId: null, qemu: null,
    sourceSopsFile: ($machine | path join "secrets.enc.json"),
    projectHash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    disks: ["/dev/installation-test"], sshHostPublicKey: null
  } | to json | save $target
  let calls = $env.TEST_WORK | path join "calls.jsonl"
  let installation = $env.TEST_WORK | path join "installation.json"
  let bin_directory = $env.TEST_WORK | path join "bin"
  mkdir $bin_directory
  for command in [nix ssh git nixos-anywhere] {
    let executable = $bin_directory | path join $command
    [
      $"#!($nu.current-exe) --no-config-file"
      "def --wrapped main [...args: string] {"
      $"  exec ($nu.current-exe | to nuon) --no-config-file --no-std-lib --no-history ($fixture_file | to nuon) external ($command | to nuon) ...$args"
      "}"
    ] | str join "\n" | save $executable
    chmod 0755 $executable
  }

  $env.PRJ_ROOT = $project
  $env.PRJ_DATA_DIR = $data
  $env.TARGET = $target
  $env.CALLS = $calls
  $env.INSTALLATION = $installation
  $env.PATH = $env.PATH | prepend $bin_directory

  cli [] --error "Missing confirmations: WIPE_ALL_DISKS,WIPE_NIXOS"
  cli [--allow WIPE_ALL_DISKS] --error "Missing confirmations: WIPE_NIXOS"
  check (not ($installation | path exists)) "Unconfirmed wipe reached the installer"

  for extra in [[] [--phases "disko,install"] [--phases disko]] {
    let captured = cli [--disko-mode mount ...$extra]
    check ((option-values $captured.args "--disko-mode") == [mount]) "Mount mode was not forwarded"
    check ($captured.target.diskoMode == "mount") "Mount mode was not recorded in the installation target"
    let expected_phases = if ($extra | is-empty) { "disko,install" } else { $extra.1 }
    check ((option-values $captured.args "--phases") == [$expected_phases]) "Unexpected installation phases"
    check ("--generate-hardware-config" not-in $captured.args) "Recovery VM hardware captured"
    check (not ($captured | to json | str contains "WIPE")) "Mount mode requested a wipe confirmation"
    check (not ($machine | path join "facter.json" | path exists)) "Recovery VM hardware report was written"
  }

  let captured = cli [--allow "WIPE_ALL_DISKS,WIPE_NIXOS"]
  check ((option-values $captured.args "--disko-mode") == [disko]) "Default disko mode changed"
  check ($captured.target.diskoMode == "disko") "Default mode was not recorded in the installation target"
  check ("--phases" not-in $captured.args) "Default installation phases were overridden"
  check ((option-values $captured.args "--generate-hardware-config") == [nixos-facter]) "Default hardware report generation changed"

  let captured = cli [--disko-mode mount --generate-hardware-config nixos-facter /explicit.json]
  check ((option-values $captured.args "--generate-hardware-config") == [nixos-facter]) "Explicit hardware generation was ignored"
  check ("/explicit.json" in $captured.args) "Explicit hardware report path changed"
  cli [--disko-mode format] --error "Unsupported disko mode"
  check (not ($calls | path exists)) "Invalid mode reached secrets or the target"
  cli [--disko-mode mount] --error "was not found" --overrides {MISSING_DISK: "1"}
  check (not ($installation | path exists)) "Missing target disk reached the installer"
  print "Mount mode preserves the selected mount action, refuses unsafe fallback, skips wipe confirmations and recovery hardware capture."
}

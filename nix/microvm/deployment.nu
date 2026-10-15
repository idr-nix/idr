# Reuse the installer decryptor and the ordinary IDR atomic file receiver.
def shell-quote [value: string] {
  $"'($value | str replace --all "'" "'\\''")'"
}

def main [manifest_file: path, ssh_config: path, target: string, scratch: path] {
  ulimit --core-size 0
  let manifest = open --raw $manifest_file | from json
  with-env {PRJ_DATA_DIR: $scratch} {
    with-disko-files {preFormatFiles: {}, postFormatFiles: $manifest.postFormatFiles} {|files|
      for file in $files.post_format_files {
        let metadata = $manifest.postFormatFiles | values | where path == $file.dst | first
        if $metadata.publicKey != null {
          let derived = ssh-keygen -y -P "" -f $file.src | complete
          let actual = $derived.stdout | str trim | split row " " | first 2 | str join " "
          let expected = $metadata.publicKey | str trim | split row " " | first 2 | str join " "
          if $derived.exit_code != 0 or $actual != $expected {
            error make {msg: $"SSH host key for ($file.dst) does not match its declared public key."}
          }
        }
        let content = open --raw $file.src
        let hash = $content | hash sha256
        let check = [$manifest.receiver "check" $file.dst $hash] | each {|arg| shell-quote $arg } | str join " "
        let checked = ssh -F $ssh_config $target $check | complete
        if $checked.exit_code != 0 {
          error make {msg: $"Could not check ($file.dst): ($checked.stderr | str trim)"}
        }
        if ($checked.stdout | str trim) == "unchanged" {
          continue
        }
        let install = [$manifest.receiver "install" $file.dst $hash] | each {|arg| shell-quote $arg } | str join " "
        let copied = $content | ssh -F $ssh_config $target $install | complete
        if $copied.exit_code != 0 {
          error make {msg: $"Could not copy ($file.dst): ($copied.stderr | str trim)"}
        }
        print $"Updated guest file: ($file.dst)"
      }
    }
  }
}

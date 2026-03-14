export def read-image [image: string, offset: int, length: int] {
  let result = qemu-io -r -f qcow2 -c $"read -v ($offset) ($length)" $image | complete
  if $result.exit_code != 0 {
    error make {msg: $"Could not read ($image): ($result.stderr | str trim)"}
  }
  $result.stdout | lines
    | parse -r '^[0-9a-f]+:  (?<bytes>.*?)  '
    | get bytes | str join "" | str replace --all " " "" | decode hex
}

# Automatic project maintenance can only update files this operator can decrypt.
# Keep explicit user commands strict; this helper is only for startup hooks.
export def decrypt-if-accessible [file: path, --output: path] {
  let output_args = if $output == null { [] } else { ["--output" $output] }
  let result = sops decrypt ...$output_args $file | complete
  if $result.exit_code == 128 {
    # SOPS CouldNotRetrieveKey: none of the available identities can recover
    # this file's data key. Parsing, ciphertext and MAC failures have other codes.
    return null
  }
  if $result.exit_code != 0 {
    error make {msg: $"Could not decrypt ($file): ($result.stderr | str trim)"}
  }
  $result.stdout
}

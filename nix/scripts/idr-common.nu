export def host-data-dir [] {
  let host_id = if ("/etc/machine-id" | path exists) {
    open --raw /etc/machine-id | str trim | default --empty (sys host | get hostname)
  } else {
    sys host | get hostname
  }

  $env.PRJ_DATA_DIR | path join $host_id
}

export def host-socket-prefix [name: string] {
  let host_hash = host-data-dir | path basename | hash sha256 | str substring 0..<16
  $"($name)-($host_hash)"
}

export def workspace-id [] {
  let workspace_id = if "IDR_WORKSPACE_ID" in $env {
    $env.IDR_WORKSPACE_ID
  } else {
    let git_paths = git rev-parse --path-format=absolute --git-dir --git-common-dir | complete
    let paths = $git_paths.stdout | lines
    if $git_paths.exit_code == 0 and $paths.0 != $paths.1 {
      $paths.0 | hash sha256 | str substring 0..<8
    } else {
      "00000000"
    }
  } | str downcase

  if $workspace_id !~ '^[0-9a-f]{8}$' {
    error make {msg: "IDR_WORKSPACE_ID must contain 8 hexadecimal digits."}
  }

  $workspace_id
}

export def save-atomic [file: string] {
  let content = $in
  let destination = $file | path expand
  let temporary_file = ($destination | path dirname | path join $".idr-save-(random chars)")

  try {
    do --capture-errors {
      touch $temporary_file
      if ($destination | path exists) {
        chown --reference $destination $temporary_file
        ^cp --attributes-only --preserve=mode $destination $temporary_file
      }
      $content | save -f $temporary_file
      ^mv -Tf $temporary_file $destination
    }
  } catch {|err|
    rm --force $temporary_file
    error make $err.raw
  }
}

export def with-disko-files [
  metadata: record
  # Function which takes
  #   {
  #     temporary_directory: string,
  #     pre_format_files: list<{src: string, dst: string}>,
  #     post_format_files: list<{src: string, dst: string}>,
  #     pre_format_files_path: string,
  #     post_format_files_path: string,
  #   }
  #
  # Temporary folder will be created, and populated with necessary files, and this callback will be executed.
  # Afterwards, the files will be removed from temporary folder.
  callback: closure
] {
  let tmp_dir = $env.PRJ_DATA_DIR | path expand | path join $"idr-disko-files-(random chars)"
  let pre_format_files_path = $tmp_dir | path join "pre-format-files"
  let post_format_files_path = $tmp_dir | path join "post-format-files"

  try {
    mkdir $tmp_dir
    chmod 0700 $tmp_dir
    mkdir $pre_format_files_path $post_format_files_path

    (
      $metadata.preFormatFiles | values | each {merge { dest_base: $pre_format_files_path }}
    ) ++ (
      $metadata.postFormatFiles | values | each {merge { dest_base: $post_format_files_path }}
    ) | each {|entry|
      let dest = $entry.dest_base | path join ($entry.path | str trim --char "/")
      let secrets_file = $entry.sopsFile
      let extract_args = if $entry.key? == null {
        []
      } else {
        ["--extract" ([$entry.key] | to json -r)]
      }

      print $"Decrypting ($secrets_file) to ($dest)"

      mkdir ($dest | path dirname)
      let decrypted = sops decrypt ...$extract_args --output $dest $secrets_file | complete
      if $decrypted.exit_code != 0 {
        error make {msg: $"Could not decrypt ($secrets_file): ($decrypted.stderr | str trim)"}
      }
      chmod 0600 $dest
    } | ignore

    # Pool creation must use the installed system's host identity in both installers.
    let hostid_files = if $metadata.hostId? != null {
      if ($metadata.preFormatFiles | values | any {|file| $file.path == "/etc/hostid"}) {
        error make {msg: "/etc/hostid is supplied from networking.hostId; remove the conflicting preFormatFiles entry."}
      }
      let dest = $pre_format_files_path | path join "etc/hostid"
      let bytes = $metadata.hostId | decode hex
      mkdir ($dest | path dirname)
      (if $metadata.hostIdIsBigEndian { $bytes } else { $bytes | bytes reverse }) | save -f $dest
      [{src: $dest, dst: "/etc/hostid"}]
    } else {
      []
    }

    do $callback {
      temporary_directory: $tmp_dir
      pre_format_files_path: $pre_format_files_path
      post_format_files_path: $post_format_files_path
      pre_format_files: ($metadata.preFormatFiles | values | each {|file| ({
        src: ($pre_format_files_path | path join ($file.path | str trim --char "/"))
        dst: $file.path
      })} | append $hostid_files | uniq)
      post_format_files: ($metadata.postFormatFiles | values | each {|file| ({
        src: ($post_format_files_path | path join ($file.path | str trim --char "/"))
        dst: $file.path
      })} | uniq)
    }
    null
  } finally {|error|
    rm --recursive --force $tmp_dir
    if $error != null {
      error make $error
    }
  }
}

const script_path = path self

use idr-common.nu [with-disko-files host-data-dir save-atomic]

def receipt-path [directory: string, machine: string, format: string] {
  $directory | path join $".idr-mk-images-($machine)-($format).json"
}

# Only complete standalone image sets can be reused. In particular, raw image
# detection alone cannot distinguish a truncated file from a valid small disk.
def image-size [size: string] {
  let parsed = $size | parse --regex '^(?<amount>[0-9]+)(?<unit>[KMGTP]?)$' | first
  let factor = {K: 1024, M: 1048576, G: 1073741824, T: 1099511627776, P: 1125899906842624}
  let bytes = ($parsed.amount | into int) * ($factor | get -o $parsed.unit | default 1)
  (($bytes + 511) // 512) * 512
}

def valid-images [directory: string, format: string, disks: list] {
  $disks | all {|disk|
    try {
      let file = $directory | path join $"($disk.imageName).($format)"
      let info = qemu-img info --output=json -f $format $file | from json
      (($info.format == $format)
        and ($info.virtual-size == (image-size $disk.size))
        and ($info.backing-filename? == null)
        and (if $format == "raw" {
          (^stat -L --format %s $file | into int) == (image-size $disk.size)
        } else {
          (qemu-img check -f $format $file | complete | get exit_code) in [0 63]
        }))
    } catch { false }
  }
}

def reusable [directory: string, machine: string, format: string, identity: record, disks: list] {
  try {
    let receipt = open --raw (receipt-path $directory $machine $format) | from json
    (($receipt == {version: 1, identity: $identity, format: $format})
      and (valid-images $directory $format $disks))
  } catch { false }
}

def write-receipt [directory: string, machine: string, format: string, identity: record] {
  {version: 1, identity: $identity, format: $format}
    | to json -r | save-atomic (receipt-path $directory $machine $format)
}

# Progress records live only beside our private RAW staging set. File identity
# detects replacement or modification of outputs completed before an interruption.
def image-signature [file: string] {
  ^stat --printf '%i:%s:%y:%z' $file | str trim
}

def main [
  --build-memory (-m): int = 16384 # Memory in MiB for the nested Disko build VM
  --jobs (-j): int = 0 # Concurrent image conversions (0: automatic, at most two)
  --type (-t): string = "qcow2" # raw|qcow2|vmdk, etc - any format supported by qemu-img
  --source: string # Reuse images from this directory (default: the machine's idr -D disk directory)
  --force (-f) # Generate fresh installed images instead of reusing images
  machine_name: string
  destination: string = "."
] {
  if "PRJ_ROOT" not-in $env {
    error make {msg: "PRJ_ROOT environment variable is required."}
  }
  if $type !~ '^[a-zA-Z0-9_-]+$' {
    error make {msg: "Invalid image format"}
  }
  if $jobs < 0 {
    error make {msg: "Conversion jobs must be zero (automatic) or a positive integer"}
  }
  let destination = $destination | path expand
  let standard_source = host-data-dir | path join $machine_name "qemu" | path expand
  let source = if $source != null { $source | path expand } else { $standard_source }
  # Serialize exports with the runner, and with other exports. Writable sources
  # need a lock even when a copied archive omitted it. Read-only archives without
  # a runner lock cannot be written by another exporter. The runner passes its held
  # directory so its child does not reacquire the same flock.
  let held = $env.IDR_MK_IMAGES_INTERNAL_LOCKS_JSON? | default "[]" | from json
  let runner_lock = $env.IDR_MK_IMAGES_INTERNAL_RUNNER_DIR? | default ""
  let lock_source = ($source | path join ".idr-qemu.lock" | path exists) or (
    ($source | path exists) and ((^test -w $source | complete | get exit_code) == 0)
  )
  let locks = ([$destination] ++ (if $lock_source { [$source] } else { [] }))
    | uniq | sort | where {|directory| $directory not-in $held and $directory != $runner_lock}
  if ($locks | is-not-empty) {
    let directory = $locks | first
    $env.IDR_MK_IMAGES_INTERNAL_LOCKS_JSON = ($held | append $directory | to json -r)
    let arguments = (["--build-memory" ($build_memory | into string) "--jobs" ($jobs | into string) "--type" $type "--source" $source]
      ++ (if $force { ["--force"] } else { [] }) ++ [$machine_name $destination])
    try {
      (run-external "flock" "--close" "--nonblock" "--conflict-exit-code" "75"
        ($directory | path join ".idr-qemu.lock")
        $nu.current-exe "-n" "--no-std-lib" "--no-history" $script_path ...$arguments)
    } catch {
      let code = $env.LAST_EXIT_CODE
      if $code == 75 {
        print --stderr $"idr-mk-images: images are in use in ($directory); stop the VM before exporting."
      }
      exit $code
    }
    exit 0
  }

  let metadata = nix --offline eval $"($env.PRJ_ROOT)#nixosConfigurations.\"($machine_name)\".config.system.build.idr.meta.disko" --json | from json
  let disks = $metadata.disks | values
  let names = $disks | get imageName
  let internal = "IDR_MK_IMAGES_INTERNAL_IMAGE_NAMES_JSON" in $env
  let requested = if $internal { $env.IDR_MK_IMAGES_INTERNAL_IMAGE_NAMES_JSON | from json } else { $names }
  if ($requested | any {|name| $name not-in $names}) {
    error make {msg: "Unknown disk image name in internal selection"}
  }
  let selected = $disks | where {|disk| $disk.imageName in $requested}
  if ($selected | is-empty) { return }

  # Installation files are decrypted outside Nix. Bind their encrypted bytes and
  # installation metadata to the builder; never hash decrypted secrets.
  let installation_files = ["preFormatFiles" "postFormatFiles"] | each {|kind|
    $metadata | get $kind | values | each {|entry|
      {path: $entry.path, key: $entry.key, encrypted: (open --raw $entry.sopsFile | hash sha256)}
    }
  }
  let builder = nix --offline eval --raw $"($env.PRJ_ROOT)#idrDiskoImagesScript.\"($machine_name)\".drvPath" | str trim
  let identity = {
    builder: $builder
    disks: $metadata.disks
    installationFiles: $installation_files
    hostId: $metadata.hostId?
    hostIdIsBigEndian: $metadata.hostIdIsBigEndian?
  }

  let candidates = if $force { [] } else {
    [$destination $source] | uniq | each {|directory|
      [$type "qcow2" "raw" "vmdk"] | uniq | each {|format|
        {directory: $directory, format: $format}
      }
    } | flatten
  }
  let cached = $candidates | where {|candidate|
    reusable $candidate.directory $machine_name $candidate.format $identity $disks
  } | first 1
  let staging = $destination | path join (if $internal { $".idr-mk-images-($machine_name)-pending" } else { $".idr-mk-images-(random chars)" })
  let resume = $internal and not $force and (reusable $staging $machine_name "raw" $identity $disks)
  let generated = $resume or ($cached | is-empty)
  let input = if $generated { {directory: $staging, format: "raw"} } else { $cached | first }

  let progress_file = $staging | path join $"converted-($type).json"
  mut progress = if $resume and ($progress_file | path exists) {
    try { open --raw $progress_file | from json } catch { {completeGeneration: false, images: {}} }
  } else { {completeGeneration: false, images: {}} }

  try {
    if $generated and not $resume {
      if ($staging | path exists) { rm -rf $staging }
      mkdir $staging
      chmod 0700 $staging
      with-disko-files $metadata {|disko_files|
        let image_builder = (do --capture-errors {
          nix --offline -L build --no-link --print-out-paths $"($env.PRJ_ROOT)#idrDiskoImagesScript.\"($machine_name)\""
        } | str trim)
        let nix_build_cores = if ("NIX_BUILD_CORES" in $env) and (not ($env.NIX_BUILD_CORES | is-empty)) {
          $env.NIX_BUILD_CORES
        } else {
          # The generated VM runner's stdenv expands zero to all visible CPUs.
          "0"
        }

        with-env {
          enableParallelBuilding: "1"
          NIX_BUILD_CORES: $nix_build_cores
        } {
          if "IDR_IMAGE_BUILD_VM" in $env {
            let files_dir = $staging | path join ".idr-files"
            let share = {|kind, entries|
              $entries | enumerate | each {|it|
                let name = $"($kind)-($it.index)"
                cp -r $it.item.src ($files_dir | path join $name)
                [$"--($kind)-format-files" $"/build/.idr-files/($name)" $it.item.dst]
              } | flatten
            }
            mkdir $files_dir
            try {
              let file_args = (do $share "pre" $disko_files.pre_format_files) ++ (do $share "post" $disko_files.post_format_files)
              do --capture-errors {
                (run-external
                  $env.IDR_IMAGE_BUILD_VM
                  "--memory" ($build_memory + 2048)
                  "--build-dir" $staging
                  "--closure" $image_builder
                  "--"
                  "env" "enableParallelBuilding=1" $"NIX_BUILD_CORES=($nix_build_cores)"
                  $image_builder "--build-memory" $build_memory ...$file_args
                )
              }
            } catch {|err|
              rm -rf $files_dir
              error make $err.raw
            }
            rm -rf $files_dir
          } else {
            do --capture-errors {
              cd $staging
              (run-external
                $image_builder
                "--build-memory" $build_memory
                ...($disko_files.pre_format_files | each {|it| ["--pre-format-files" $it.src $it.dst]} | flatten)
                ...($disko_files.post_format_files | each {|it| ["--post-format-files" $it.src $it.dst]} | flatten)
              )
            }
          }
        }
      }

      if not (valid-images $staging "raw" $disks) {
        error make {msg: "Image builder did not produce a complete valid RAW image set"}
      }
      write-receipt $staging $machine_name "raw" $identity
      $progress = {completeGeneration: (($selected | length) == ($disks | length)), images: {}}
      $progress | to json -r | save-atomic $progress_file
    }

    print --stderr $"idr-mk-images: (if $generated { 'using generated' } else { 'reusing' }) ($input.format) images from ($input.directory)"
    if $input.directory != $destination or $input.format != $type {
      # Invalidate before replacing any member. A failure must not certify a
      # mixture of an earlier generation and newly converted images.
      rm -f (receipt-path $destination $machine_name $type)
      let opts = match $type {
        "qcow2" => ["-c" "-o" "compression_type=zstd"]
        "vmdk" => ["-c" "-o" "subformat=streamOptimized"]
        _ => []
      }
      # Converters need much less memory than the installation VM. Keep automatic
      # concurrency conservative, and allow a serial override for slower storage.
      let workers = if $jobs == 0 {
        let memory_jobs = try { (sys mem | get available | into int) // 1073741824 } catch { 1 }
        let cpu_jobs = try { ^nproc | into int } catch { 1 }
        [([2 $memory_jobs $cpu_jobs] | math min) 1] | math max
      } else { $jobs }
      for batch in ($selected | chunks $workers) {
        # Every worker returns a result, including failures, so all workers finish
        # before cleanup. Only this parent publishes images and updates progress.
        let converted = $batch | par-each --threads $workers {|disk|
          let temporary = $destination | path join $".idr-convert-(random chars).partial"
          try {
            do --capture-errors {
              (qemu-img convert -f $input.format -O $type ...$opts
                ($input.directory | path join $"($disk.imageName).($input.format)") $temporary)
            }
            {disk: $disk, temporary: $temporary, failure: null}
          } catch {|err|
            rm -f $temporary
            {disk: $disk, temporary: $temporary, failure: ($err.json | from json)}
          }
        }
        try {
          for result in ($converted | where failure == null) {
            let output = $destination | path join $"($result.disk.imageName).($type)"
            do --capture-errors { ^mv -Tf $result.temporary $output }
            if $generated {
              $progress.images = $progress.images | upsert $result.disk.imageName (image-signature $output)
              $progress | to json -r | save-atomic $progress_file
            }
          }
          let failures = $converted | where failure != null
          if ($failures | is-not-empty) { error make ($failures | first | get failure) }
        } catch {|err|
          for result in $converted { rm -f $result.temporary }
          error make $err.raw
        }
      }
    }
    let completed_images = $progress.images
    let resumed_complete = $generated and $progress.completeGeneration and ($disks | all {|disk|
      let recorded = $completed_images | get -o $disk.imageName
      $recorded != null and (try {
        $recorded == (image-signature ($destination | path join $"($disk.imageName).($type)"))
      } catch { false })
    })
    if ($selected | length) == ($disks | length) or $resumed_complete {
      if not (valid-images $destination $type $disks) {
        error make {msg: "Conversion did not produce a complete valid image set"}
      }
      write-receipt $destination $machine_name $type $identity
    }
    if $generated { rm -rf $staging }
  } catch {|err|
    # Retain the runner's complete pending RAW set for interrupted conversions.
    if not $internal { rm -rf $staging }
    error make $err.raw
  }
}

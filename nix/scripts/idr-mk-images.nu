use idr-common.nu [with-disko-files]

def main [
  --build-memory (-m): int = 16384 # Memory in MiB for the nested Disko build VM
  --type (-t): string = "qcow2" # raw|qcow2|vmdk, etc - any format supported by qemu-img
  machine_name: string
  destination: string = "."
] {
  if "PRJ_ROOT" not-in $env {
    print "PRJ_ROOT environment variable is required."
    exit 1
  }

  cd $destination

  let disks = (nix eval
    $"($env.PRJ_ROOT)#nixosConfigurations.\"($machine_name)\".config.disko.devices.disk"
    --apply "c: builtins.map (it: it.imageName) (builtins.attrValues c)"
    --json
    | from json
  )

  let internal_image_selection = "IDR_MK_IMAGES_INTERNAL_IMAGE_NAMES_JSON" in $env
  let requested_images = if $internal_image_selection {
    $env.IDR_MK_IMAGES_INTERNAL_IMAGE_NAMES_JSON | from json
  } else {
    $disks
  }
  let unknown_images = $requested_images | where {|image| $image not-in $disks}

  if not ($unknown_images | is-empty) {
    print --stderr $"Unknown disk image name(s): ($unknown_images | str join ', ')"
    exit 2
  }

  let selected_disks = $disks | where {|disk| $disk in $requested_images}
  let raw_images_marker = $".idr-mk-images-($machine_name)-raw-complete"
  let raw_images_marker_matches = if $internal_image_selection and ($raw_images_marker | path exists) {
    try {
      (open --raw $raw_images_marker | from json) == $disks
    } catch {
      false
    }
  } else {
    false
  }
  let selected_raw_images_exist = (
    not ($selected_disks | is-empty)
    and $raw_images_marker_matches
    and ($selected_disks | all {|disk| $"($disk).raw" | path exists})
  )

  if (not ($selected_disks | is-empty)) and (not $selected_raw_images_exist) {
    let build_dir = $nu.temp-dir | path join $"idr-mk-images-(random chars)"

    try {
      mkdir $build_dir
      chmod 0700 $build_dir
      let metadata = nix eval $"($env.PRJ_ROOT)#nixosConfigurations.\"($machine_name)\".config.system.build.idr.meta.disko" --json | from json
      with-disko-files $metadata {|disko_files|
        let image_builder = (do --capture-errors {
          nix --offline -L build --print-out-paths $"($env.PRJ_ROOT)#nixosConfigurations.\"($machine_name)\".config.system.build.diskoImagesScript"
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
          do --capture-errors {
            cd $build_dir
            (run-external
              $image_builder
              "--build-memory" $build_memory
              ...($disko_files.pre_format_files | each {|it| ["--pre-format-files" $it.src $it.dst]} | flatten)
              ...($disko_files.post_format_files | each {|it| ["--post-format-files" $it.src $it.dst]} | flatten)
            )
          }
        }
      }

      let missing_images = $disks | where {|disk| not ($build_dir | path join $"($disk).raw" | path exists)}
      if ($missing_images | is-not-empty) {
        error make {msg: $"Image builder did not produce: ($missing_images | str join ', ')"}
      }

      # Keep the previous raw set and its marker until generation is complete.
      rm -f $raw_images_marker
      $disks | each {|disk|
        do --capture-errors {
          ^mv -Tf ($build_dir | path join $"($disk).raw") $"($disk).raw"
        }
      } | ignore

      if $internal_image_selection {
        # This marker identifies a successfully generated raw set. It deliberately
        # survives only an interrupted runner conversion so all resumed disks come
        # from the same Disko run as any QCOW2 files already completed.
        $disks | to json -r | save -f $raw_images_marker
      }
    } catch {|err|
      rm -rf $build_dir
      error make $err.raw
    }

    rm -rf $build_dir
  }

  if $type != "raw" {
    let opts = match $type {
      "qcow2" => ["-c" "-o" "compression_type=zstd"]
      "vmdk" => ["-c" "-o" "subformat=streamOptimized"]
      _ => []
    }

    $selected_disks | each {|disk|
      let output_image = $"($disk).($type)"
      let temporary_image = $"($output_image).partial"
      rm -f $temporary_image

      let conversion = do {
        qemu-img convert -O $type ...$opts $"($disk).raw" $temporary_image
      } | complete

      if $conversion.exit_code != 0 {
        rm -f $temporary_image
        print --stderr $conversion.stderr
        exit $conversion.exit_code
      }

      do --capture-errors {
        ^mv -Tf $temporary_image $output_image
      }
      rm $"($disk).raw"
    }

    $disks
      | each {|disk| $"($disk).raw" }
      | where {|image| $image | path exists}
      | each {|image| rm -f $image}
      | ignore

    rm -f $raw_images_marker
  }
}

# The wrapper imports IDR's with-disko-files before sourcing this file.

def --wrapped checked [...arguments: string] {
  let result = run-external ...$arguments | complete
  if $result.exit_code != 0 {
    error make {msg: $"($arguments | first) failed: ($result.stderr | str trim)"}
  }
  $result.stdout | str trim
}

def datasets [parent: string] {
  let parent_type = checked zfs list -H -o type $parent
  if $parent_type != "filesystem" {
    error make {msg: $"The parent ZFS dataset ($parent) must already exist and be a filesystem."}
  }
  checked zfs list -H -p -o name,type,volsize -r -d 1 $parent
    | lines
    | split column "\t" name type size
}

def direct-property [dataset: string, property: string] {
  let value = checked zfs get -H -p -o value,source $property $dataset | split row "\t"
  if ($value | length) != 2 or $value.1 not-in ["local" "received"] {
    return null
  }
  $value.0
}

def owned-volume [volume: record, owner: string] {
  if $volume.type != "volume" or (direct-property $volume.name "org.idr:microvm") != $owner {
    error make {msg: $"Refusing to modify ($volume.name): it is not a volume owned by ($owner)."}
  }
}

def device-path [dataset: string] {
  let device = $"/dev/zvol/($dataset)"
  checked udevadm wait --timeout=60 --settle $device | ignore
  checked test -b $device | ignore
  $device
}

def publish [pending: string, dataset: string, pool: string] {
  checked zfs rename $pending $dataset | ignore
  checked zpool sync $pool | ignore
  device-path $dataset | ignore
}

def file-test [flag: string, file: string] {
  (run-external test $flag $file | complete).exit_code == 0
}

def with-images [manifest: record, state: string, disks: list, callback: closure] {
  let scratch = checked mktemp -d ($state | path join ".bootstrap-XXXXXXXXXX")
  try {
    with-env {PRJ_DATA_DIR: $scratch} {
      with-disko-files $manifest.metadata {|files|
        let file_args = (
          ($files.pre_format_files | each {|file| ["--pre-format-files" $file.src $file.dst] } | flatten)
          ++ ($files.post_format_files | each {|file| ["--post-format-files" $file.src $file.dst] } | flatten)
        )
        cd $scratch
        do --capture-errors {
          run-external $manifest.builder "--build-memory" ($manifest.buildMemoryMiB | into string) ...$file_args
        }
      }
    }

    # Disko builds the complete guest layout once, including filesystems that
    # span disks. Only blank or missing destinations receive these images.
    let images = $disks | reduce -f {} {|disk, images|
      let image = $scratch | path join $"($disk.imageName).raw"
      let info = checked qemu-img info --output=json -f raw $image | from json
      let size = if $disk.sizeMiB == null { $info.virtual-size } else { $disk.sizeMiB * 1048576 }
      if $size <= 0 or $info.virtual-size <= 0 or $info.virtual-size > $size {
        error make {msg: $"The installed image for ($disk.name) does not fit the configured VM disk."}
      }
      $images | insert $disk.name {path: $image, source_size: $info.virtual-size, size: $size, scratch: $scratch}
    }
    do $callback $images
  } finally {|error|
    cd $state
    checked rm --recursive --force -- $scratch | ignore
    if $error != null {
      error make $error
    }
  }
}

def inspect-zvol [manifest: record, disk: record] {
  let dataset = $disk.dataset
  let parts = $dataset | split row "/"
  if ($parts | length) < 2 or ($parts | any {|part| $part in ["" "." ".."] }) {
    error make {msg: "A VM zvol must be a child of an existing ZFS filesystem dataset."}
  }
  let parent = $parts | drop | str join "/"
  let pending = $"($dataset)-installing"
  let existing = datasets $parent
  let final = $existing | where name == $dataset | get -o 0
  if $final != null {
    owned-volume $final $manifest.unitName
    if (direct-property $dataset "org.idr:installed") != "yes" {
      error make {msg: $"Refusing to overwrite the existing uninitialized VM volume ($dataset)."}
    }
    device-path $dataset | ignore
    return {disk: $disk, action: "preserve"}
  }

  let interrupted = $existing | where name == $pending | get -o 0
  if $interrupted != null {
    owned-volume $interrupted $manifest.unitName
    let installed = direct-property $pending "org.idr:installed"
    if $installed == "yes" {
      return {disk: $disk, action: "publish-zvol"}
    }
    if $installed != "no" {
      error make {msg: $"Refusing to overwrite ($pending): its installation state is unknown."}
    }
  }
  {disk: $disk, action: "create-zvol", interrupted: ($interrupted != null)}
}

def image-info [path: string, format: string] {
  let info = checked qemu-img info --output=json $path | from json
  if $format == "raw" {
    return $info
  }
  if $info.format != $format {
    error make {msg: $"Existing image ($path) has format ($info.format), but the configured format is ($format)."}
  }
  if ($info.backing-filename? | default "") != "" {
    error make {msg: $"Backing files are not supported for the VM disk ($path). Use a standalone image."}
  }
  let features = $info.format-specific?.data? | default {}
  if ($features.data-file? | default "") != "" or ($features.extended-l2? | default false) {
    error make {msg: $"External data files and extended L2 tables are not supported for the VM disk ($path)."}
  }
  $info
}

def unused-disk [path: string, format: string] {
  if $format == "qcow2" {
    # A QCOW2 header is not a guest partition table. Only an entirely zero or
    # unallocated virtual disk is safe to initialize without exporting its data.
    checked qemu-img map --output=json -f qcow2 $path | from json | all {|extent| $extent.zero == true }
  } else {
    # Probe the selected device itself, including when it is a host partition.
    # Filesystem and RAID signatures are preserved too. Errors fail closed.
    let signatures = checked wipefs --no-act --json --output TYPE,USAGE $path | from json
    $signatures.signatures | is-empty
  }
}

def locked-disk [disk: record] {
  let descriptors = $env.IDR_MICROVM_DISK_FDS? | default "{}" | from json
  let descriptor = $descriptors | get -o $disk.name
  if $descriptor == null {
    error make {msg: $"The disk ($disk.path) appeared after provisioning started. Restart the installation service to lock and inspect it."}
  }
  let pinned = $"/proc/self/fd/($descriptor)"
  let locked = checked stat --dereference --format=%d:%i $pinned
  if (checked stat --dereference --format=%d:%i $disk.path) != $locked {
    error make {msg: $"The disk path ($disk.path) changed after it was locked. Refusing to initialize it."}
  }
  $pinned
}

def check-installable-block [pinned: string, path: string] {
  let device_id = checked stat --dereference --format=%t:%T $pinned | split row ":" | each {|part| $part | into int --radix 16 }
  let holders = $"/sys/dev/block/($device_id.0):($device_id.1)/holders"
  checked test -d $holders | ignore
  if (checked ls --almost-all -- $holders) != "" {
    error make {msg: $"Refusing to initialize ($path): it is in use by another block device."}
  }
}

def inspect-disk [manifest: record, disk: record] {
  if $disk.provisioning == "zvol" {
    return (inspect-zvol $manifest $disk)
  }
  if $disk.provisioning == "none" {
    return {disk: $disk, action: "preserve"}
  }
  let block_device = $disk.provisioning == "block"
  if $block_device {
    if not (file-test "-b" $disk.path) or $disk.format != "raw" {
      error make {msg: $"The configured VM disk ($disk.path) must be an existing RAW block device."}
    }
  } else if $disk.provisioning == "image" {
    if (file-test "-L" $disk.path) or ((file-test "-e" $disk.path) and not (file-test "-f" $disk.path)) {
      error make {msg: $"Refusing to provision ($disk.path): managed images must be regular files, not devices, directories or symlinks."}
    }
    if not (file-test "-f" $disk.path) {
      return {disk: $disk, action: "create-image"}
    }
  } else {
    error make {msg: $"Unsupported provisioning mode: ($disk.provisioning)"}
  }

  let pinned = locked-disk $disk
  if not $block_device {
    let info = image-info $pinned $disk.format
    # Raw storage may contain a whole-disk LUKS volume or another recognized
    # header. Preserve those bytes instead of treating them as an empty image.
    if $disk.format == "raw" and $info.format != "raw" {
      return {disk: $disk, action: "preserve"}
    }
  }
  if not (unused-disk $pinned $disk.format) {
    return {disk: $disk, action: "preserve"}
  }
  if $block_device {
    check-installable-block $pinned $disk.path
  }
  {disk: $disk, action: "populate", block_device: $block_device}
}

def check-capacity [plan: record, image: record] {
  let disk = $plan.disk
  let pinned = locked-disk $disk
  let size = if $plan.block_device {
    checked blockdev --getsize64 $pinned | into int
  } else {
    (image-info $pinned $disk.format).virtual-size
  }
  if $size < $image.source_size and ($plan.block_device or $size != 0) {
    error make {msg: $"The disk ($disk.path) is smaller than the installed image. Existing disks are not resized."}
  }
  $size
}

def prepare-plan [manifest: record, plan: record, image: record] {
  let disk = $plan.disk
  # Recheck all pending targets after building, before writing any destination.
  let current = inspect-disk $manifest $disk
  if $current.action in ["preserve" "publish-zvol"] {
    return $current
  }
  if $current.action != $plan.action {
    error make {msg: $"The disk ($disk.path) changed while its image was being built. Restart the installation service to inspect it again."}
  }
  if $current.action == "populate" {
    check-capacity $current $image | ignore
  }
  if $current.action == "create-image" {
    let parent = $disk.path | path dirname
    # Only new directories get these permissions; existing parents are untouched.
    checked bash -c 'umask 022; exec mkdir -p -- "$1"' mkdir $parent | ignore
    if (runuser --user microvm --group kvm -- test -x $parent | complete).exit_code != 0 {
      error make {msg: $"The microvm user with group kvm needs traversal permission on ($parent) and its parent directories."}
    }
    let source = if $disk.format == "raw" {
      $image.path
    } else {
      let converted = $image.scratch | path join $"($disk.imageName).qcow2"
      checked qemu-img convert -f raw -O qcow2 $image.path $converted | ignore
      $converted
    }
    if $image.size > $image.source_size {
      checked qemu-img resize -f $disk.format $source ($image.size | into string) | ignore
    }
    checked chown microvm:root -- $source | ignore
    checked chmod 0600 -- $source | ignore
    return ($current | insert source $source)
  }
  $current
}

def install-plan [manifest: record, plan: record, images: record] {
  let disk = $plan.disk
  if $plan.action == "preserve" {
    print $"Preserving existing disk for ($manifest.machine): ($disk.path)"
    return
  }
  if $plan.action == "publish-zvol" {
    publish $"($disk.dataset)-installing" $disk.dataset ($disk.dataset | split row "/" | first)
    print $"Finished publishing the installed disk ($disk.name) for ($manifest.machine)."
    return
  }

  let image = $images | get $disk.name
  match $plan.action {
    "create-zvol" => {
      # Only our incomplete staging volume may be discarded. Never destroy or
      # reinstall a final volume, including one whose marker is missing.
      let current = inspect-zvol $manifest $disk
      if $current.action != "create-zvol" {
        install-plan $manifest $current $images
        return
      }
      let pending = $"($disk.dataset)-installing"
      let pool = $disk.dataset | split row "/" | first
      if $current.interrupted { checked zfs destroy $pending | ignore }
      (checked zfs create -s -V ($image.size | into string)
        -o volmode=dev
        -o $"compression=($disk.compression)"
        -o $"primarycache=($disk.primarycache)"
        -o $"org.idr:microvm=($manifest.unitName)"
        -o org.idr:installed=no $pending) | ignore
      let device = device-path $pending
      if (checked blockdev --getsize64 $device | into int) < $image.source_size {
        error make {msg: $"The block device ($device) is smaller than the installed image."}
      }
      checked qemu-img convert -n -f raw -O raw $image.path $device | ignore
      checked blockdev --flushbufs $device | ignore
      checked zpool sync $pool | ignore
      checked zfs set org.idr:installed=yes $pending | ignore
      publish $pending $disk.dataset $pool
    }
    "populate" => {
      let current = inspect-disk $manifest $disk
      if $current.action == "preserve" {
        install-plan $manifest $current $images
        return
      }
      if $current.action != "populate" {
        error make {msg: $"The disk ($disk.path) changed before installation."}
      }
      let size = check-capacity $current $image
      let pinned = locked-disk $disk
      if $size == 0 {
        checked qemu-img resize -f $disk.format $pinned ($image.size | into string) | ignore
      }
      checked qemu-img convert -n -f raw -O $disk.format $image.path $pinned | ignore
      if $current.block_device {
        checked blockdev --flushbufs $pinned | ignore
      } else {
        checked sync -f $pinned | ignore
      }
    }
    "create-image" => {
      # Exclusive creation and descriptor-based metadata changes prevent a
      # concurrent file or symlink from being overwritten.
      (checked env -u POSIXLY_CORRECT cp --update=none-fail --no-target-directory
        --sparse=always --preserve=mode,ownership -- $plan.source $disk.path) | ignore
      checked sync -f $disk.path | ignore
    }
    _ => { error make {msg: $"Unsupported disk installation action: ($plan.action)"} }
  }
  print $"Installed ($manifest.machine) disk ($disk.name) on ($disk.path)."
}

def main [manifest_file: path] {
  let manifest = open --raw $manifest_file | from json
  let state = $env.STATE_DIRECTORY | path expand --strict
  # The wrapper holds the per-VM lock. Clean interrupted image-build scratch,
  # including decrypted installation files.
  for previous in (glob ($state | path join ".bootstrap-*")) {
    checked rm --recursive --force -- $previous | ignore
  }
  let plans = $manifest.disks | each {|disk| inspect-disk $manifest $disk }
  let pending = $plans | where {|plan| $plan.action in ["create-zvol" "create-image" "populate"] }
  if ($pending | is-empty) {
    for plan in $plans { install-plan $manifest $plan {} }
    return
  }
  with-images $manifest $state ($pending | get disk) {|images|
    let prepared = $plans | each {|plan|
      if $plan.action in ["create-zvol" "create-image" "populate"] {
        prepare-plan $manifest $plan ($images | get $plan.disk.name)
      } else {
        $plan
      }
    }
    for plan in $prepared { install-plan $manifest $plan $images }
  }
}

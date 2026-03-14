const script_path = path self

use idr-common.nu [host-data-dir workspace-id]
use ./idr-qemu-network.nu
use ./idr-unlock-disks.nu [unlock]
use ./idr-qemu-ready.nu [scan-host-keys]
use ./idr-ssh-key.nu

def generate-images [
  build_memory: int
  machine_name: string
  destination: string
  mk_images_script: string
  image_names: list<string>
] {
  with-env {IDR_MK_IMAGES_INTERNAL_IMAGE_NAMES_JSON: ($image_names | to json -r)} {
    do --capture-errors {
      (run-external
        $nu.current-exe "-n" "--no-std-lib" "--no-history"
        $mk_images_script
        "--build-memory" $build_memory
        $machine_name $destination
      )
    }
  }
}

def main [
  --force (-f)
  --build-memory (-m): int = 16384 # Memory in MiB for the nested Disko build VM
] {
  if "PRJ_ROOT" not-in $env {
    print "PRJ_ROOT environment variable is required."
    exit 1
  }

  if "IDR_QEMU_MACHINE" not-in $env {
    print "IDR_QEMU_MACHINE environment variable is required."
    exit 1
  }

  if "IDR_QEMU_OPTIONS_JSON" not-in $env {
    print "IDR_QEMU_OPTIONS_JSON environment variable is required."
    exit 1
  }

  if "IDR_QEMU_VNC_ENABLED" not-in $env {
    print "IDR_QEMU_VNC_ENABLED environment variable is required."
    exit 1
  }

  if "IDR_MK_IMAGES_SCRIPT" not-in $env {
    print "IDR_MK_IMAGES_SCRIPT environment variable is required."
    exit 1
  }

  if ("PRJ_DATA_DIR" not-in $env) or ($env.PRJ_DATA_DIR | is-empty) {
    print "PRJ_DATA_DIR environment variable is required."
    exit 1
  }

  let machine_name = $env.IDR_QEMU_MACHINE
  let project_root = $env.IDR_QEMU_PROJECT_ROOT? | default --empty $env.PRJ_ROOT
  let vnc_enabled = $env.IDR_QEMU_VNC_ENABLED == "true"
  let extra_qemu_options = if ("IDR_QEMU_EXTRA_OPTIONS_JSON" in $env) and (not ($env.IDR_QEMU_EXTRA_OPTIONS_JSON | is-empty)) {
    $env.IDR_QEMU_EXTRA_OPTIONS_JSON | from json
  } else {
    []
  }
  let qemu_options = ($env.IDR_QEMU_OPTIONS_JSON | from json) ++ $extra_qemu_options
  let data_dir = host-data-dir
  let qemu_dir = $data_dir | path join $machine_name "qemu"
  let machine_qemu_dir = $data_dir | path join "machine" $machine_name "qemu"
  let serial_socket = $machine_qemu_dir | path join "serial.sock" | path expand
  let vnc_socket = $machine_qemu_dir | path join "vnc.sock" | path expand
  mkdir $qemu_dir
  mkdir $machine_qemu_dir
  chmod 0700 $machine_qemu_dir

  let socket_dir = ^realpath $"--relative-to=($qemu_dir)" $machine_qemu_dir | str trim
  let serial_socket_path = $socket_dir | path join "serial.sock"

  if (($serial_socket_path | encode utf-8 | bytes length) >= 108) {
    print --stderr $"idrQemu: serial socket path is too long for a Unix socket: ($serial_socket_path)"
    print --stderr "idrQemu: use a shorter machine name."
    exit 1
  }

  if "IDR_QEMU_INTERNAL_LOCK_HELD" not-in $env {
    $env.IDR_QEMU_INTERNAL_LOCK_HELD = "1"
    $env.IDR_QEMU_ORIGINAL_SSH_AGENT = $env | select -o SSH_AUTH_SOCK SSH_AGENT_PID | to json -r

    let forwarded_args = (
      ["--build-memory" ($build_memory | into string)]
      ++ (if $force { ["--force"] } else { [] })
    )

    # Keep the disk lock in flock so background unlock processes cannot inherit it.
    try {
      (run-external
        "flock"
        "--close"
        "--nonblock"
        "--conflict-exit-code" "75"
        ($qemu_dir | path join ".idr-qemu.lock")
        "env" $"TMPDIR=($env.PRJ_DATA_DIR | path expand)"
        "ssh-agent" "-T"
        $nu.current-exe "-n" "--no-std-lib" "--no-history"
        $script_path ...$forwarded_args
      )
    } catch {
      let exit_code = $env.LAST_EXIT_CODE

      if $exit_code == 75 {
        print --stderr $"idrQemu: another instance is already using ($machine_name)"
      }

      exit $exit_code
    }

    exit 0
  }

  # OpenSSH owns the temporary agent; restore the caller's agent for SOPS and sudo.
  let qemu_agent = {socket: $env.SSH_AUTH_SOCK, pid: ($env.SSH_AGENT_PID | into int)}
  hide-env -i SSH_AUTH_SOCK SSH_AGENT_PID
  load-env ($env.IDR_QEMU_ORIGINAL_SSH_AGENT | from json)

  rm -f $serial_socket
  rm -f $vnc_socket

  let workspace_id = workspace-id
  $env.IDR_WORKSPACE_ID = $workspace_id

  let metadata = nix eval $"($env.PRJ_ROOT)#nixosConfigurations.\"($machine_name)\".config.system.build.idr.meta.disko" --json | from json
  let disks = $metadata.disks | values
  let disk_key_metadata = $metadata.preFormatFiles | get -o "/disk-key.txt"
  let disk_unlock_configured = $disk_key_metadata != null
  let auto_unlock = $env.IDR_QEMU_AUTO_UNLOCK? | default true | into bool
  let unsupported_disks = $disks | where {|disk| not $disk.qemu.supported }

  if not ($unsupported_disks | is-empty) {
    $unsupported_disks | each {|disk|
      print --stderr $"idrQemu: disk ($disk.name) uses unsupported device path ($disk.path): ($disk.qemu.reason)"
    }
    print --stderr "idrQemu supports ordered /dev/vd[a-z] and /dev/sd[a-z] paths, a single /dev/nvme0n1, plus reproducible ata-, nvme-, scsi-, virtio-, and wwn- disk IDs."
    exit 1
  }

  let expected_images = $disks | each {|disk| $qemu_dir | path join $"($disk.imageName).qcow2" }
  let raw_images = $disks | each {|disk| $qemu_dir | path join $"($disk.imageName).raw" }
  let missing_disks = $disks | where {|disk|
    not ($qemu_dir | path join $"($disk.imageName).qcow2" | path exists)
  }

  if $force {
    ($expected_images ++ $raw_images)
      | where {|image| $image | path exists}
      | each {|image| rm -f $image}
      | ignore

    (generate-images
      $build_memory
      $machine_name
      $qemu_dir
      $env.IDR_MK_IMAGES_SCRIPT
      ($disks | get imageName)
    )
  } else if not ($missing_disks | is-empty) {
    (generate-images
      $build_memory
      $machine_name
      $qemu_dir
      $env.IDR_MK_IMAGES_SCRIPT
      ($missing_disks | get imageName)
    )
  } else {
    $raw_images
      | where {|image| $image | path exists}
      | each {|image| rm -f $image}
      | ignore
  }

  let vnc_qemu_options = if $vnc_enabled {
    let qemu_vnc_socket = $socket_dir | path join "vnc.sock" | str replace --all "," ",,"

    [
      "-vnc"
      $"unix:($qemu_vnc_socket)"
    ]
  } else {
    []
  }

  let qemu_serial_socket = $serial_socket_path | str replace --all "," ",,"
  let serial_qemu_options = [
    "-chardev"
    $"socket,id=idr-serial,path=($qemu_serial_socket),server=on,wait=off,logfile=/dev/stdout,logappend=on"
    "-serial"
    "chardev:idr-serial"
  ]

  let agent = if "IDR_QEMU_SOPS_CONFIG" in $env {
    try {
      let key_directory = idr-ssh-key key-directory $machine_name
      let agent = idr-ssh-key prepare-agent $qemu_agent $env.IDR_QEMU_SOPS_FILENAME $key_directory
      print --stderr $"idrQemu: temporary SSH key is encrypted in ($key_directory)/secrets.enc.json"
      $agent
    } catch {|error|
      print --stderr $"idrQemu: temporary SSH key setup failed: ($error.msg)"
      null
    }
  } else {
    null
  }
  let can_unlock = $auto_unlock and $agent != null and $disk_unlock_configured
  if not $can_unlock {
    idr-ssh-key stop-agent $qemu_agent
  }
  let ssh_qemu_options = if $agent != null {
    ["-fw_cfg" $"name=opt/io.systemd.credentials/idr.qemu-ssh-key,string=($agent.public_key)"]
  } else {
    []
  }

  mut exit_code = 0
  try {
    let network_options = idr-qemu-network options
    if $can_unlock {
      let address = idr-qemu-network address $env.IDR_QEMU_NETWORK_PREFIX $workspace_id $env.IDR_QEMU_MACHINE_ID
      job spawn {
        try {
          let arguments = [
            "-6" "-F" "/dev/null"
            "-p" $env.IDR_QEMU_UNLOCK_PORT
            "-o" $"Hostname=($address)"
            $"root@($machine_name)"
          ]
          mut previous_host_keys = []
          loop {
            let host_keys = scan-host-keys $address ($env.IDR_QEMU_UNLOCK_PORT | into int)
            if ($host_keys | is-empty) {
              $previous_host_keys = []
            } else if $host_keys != $previous_host_keys {
              try {
                # Refresh after a boot or host-key change without evaluating Nix on every poll.
                let metadata = nix eval $"($project_root)#nixosConfigurations.\"($machine_name)\".config.system.build.idr.meta.disko" --json | from json
                let initrd_key = $metadata.postFormatFiles | values | where key == "initrd_ssh_host_ed25519_key" | first
                let public_key = open $initrd_key.sopsFile | get initrd_ssh_host_ed25519_key_pub_unencrypted
                  | split row " " | first 2 | str join " "
                if $public_key in $host_keys {
                  # Installation can take a long time; start the unlock timeout only in initrd.
                  let disk_key = $metadata.preFormatFiles | get "/disk-key.txt"
                  unlock $arguments $disk_key [$public_key] --agent $agent
                }
                $previous_host_keys = $host_keys
              } catch {|error|
                print --stderr $"idrQemu: automatic disk unlock failed: ($error.msg)"
              }
            }
            # Leave time for sshd's unauthenticated-connection penalty to expire.
            sleep 10sec
          }
        } catch {|error|
          print --stderr $"idrQemu: automatic disk unlock failed: ($error.msg)"
        }
      } | ignore
    }

    cd $qemu_dir
    $exit_code = try {
      # Keep the serial logger on a pipe even when the runner's stdout is a file.
      qemu-system-x86_64 ...$serial_qemu_options ...$vnc_qemu_options ...$network_options ...$ssh_qemu_options ...$qemu_options | cat
      0
    } catch {|error|
      print --stderr $error.msg
      $error.exit_code? | default 1
    }
  } finally {|error|
    for job in (job list) {
      try { job kill $job.id }
    }
    if $error != null {
      error make $error
    }
  }
  exit $exit_code
}

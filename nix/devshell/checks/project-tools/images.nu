use std/assert

def main [] {
  assert equal ("generated/link.txt" | path type) "symlink"
  assert equal (open --raw generated/copied.txt) "generated\n"
  assert equal (open --raw ($env.PRJ_DATA_DIR | path join "generated-hooks")) "xx"
  let directory = $env.PRJ_DATA_DIR | path join "images"
  mkdir $directory
  let names = (nix eval --json '.#nixosConfigurations.test-machine.config.disko.devices.disk'
    --apply 'disks: map (disk: disk.imageName) (builtins.attrValues disks)' | from json)
  assert equal ($names | length) 2

  # Share the system build; each public command formats and converts its own disks.
  nix --offline -L build --no-link '.#nixosConfigurations.test-machine.config.system.build.toplevel'

  let results = [qcow2 vmdk] | par-each --threads 2 {|format|
    let destination = $directory | path join $format
    mkdir $destination
    let started = date now
    print --stderr $"Building ($format) images"
    let result = with-env {NIX_BUILD_CORES: "8"} {
      idr-mk-images --build-memory 8192 --type $format test-machine $destination | complete
    }
    print --stderr $"Finished ($format) images in ((date now) - $started)"
    $result | insert format $format
  }
  for result in $results {
    assert equal $result.exit_code 0 $"($result.format) image generation failed:\n($result.stdout)\n($result.stderr)"
  }
  for format in [qcow2 vmdk] {
    let destination = $directory | path join $format
    for name in $names {
      let output = $destination | path join $"($name).($format)"
      let info = qemu-img info --output=json $output | from json
      assert equal $info.format $format
      qemu-img check $output
      assert not ($destination | path join $"($name).raw" | path exists)
      assert not ($destination | path join $"($name).($format).partial" | path exists)
    }
  }
}

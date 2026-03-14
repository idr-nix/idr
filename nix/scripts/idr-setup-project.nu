use idr-update-gitignore.nu

def main [] {
  idr-update-gitignore
  nix --offline -L flake lock
  let url = $env.IDR_GIT_URL | url parse
  let url_params = $url | get params | transpose -rd
  let shallow = $url_params | get shallow? | default false | into bool
  mut lock = open --raw flake.lock | from json
  if ($lock.nodes.idr?.locked.type | default "git") != "git" {
    mut locked = {
      type: "git"
      url: ($url | reject query fragment params | url join)
      narHash: $env.IDR_GIT_NAR_HASH
      lastModified: ($env.IDR_GIT_LAST_MODIFIED | into int)
    }

    if $env.IDR_GIT_REF != "" {
      $locked.ref = $env.IDR_GIT_REF
    }

    if $env.IDR_GIT_REV != "" {
      $locked.rev = $env.IDR_GIT_REV
    }

    if $env.IDR_GIT_DIRTY_REV != "" {
      $locked.dirtyRev = $env.IDR_GIT_DIRTY_REV
    }

    if $env.IDR_GIT_DIRTY_SHORT_REV != "" {
      $locked.dirtyShortRev = $env.IDR_GIT_DIRTY_SHORT_REV
    }

    $lock.nodes.idr.locked = $locked

    $lock.nodes.idr.original = {
      type: "git"
      url: $lock.nodes.idr.locked.url
    }

    if $shallow {
      $lock.nodes.idr.locked.shallow = true
      $lock.nodes.idr.original.shallow = true
    }

    $lock | to json --indent 2 | save -f flake.lock

    open --raw flake.nix | str replace $env.IDR_PATH $"git+($env.IDR_GIT_URL)" | save -f flake.nix

    nix --offline -L flake lock
  }

  git add flake.nix flake.lock .gitignore

  nix --offline -L develop -c true

  if (which direnv | is-not-empty) {
    direnv allow
  }

  ignore
}

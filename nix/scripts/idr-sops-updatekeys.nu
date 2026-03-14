def main [] {
  let files = (fd --hidden --exclude .git -t f -e enc.json -e enc.bin -e enc.yaml --print0 . $env.PRJ_ROOT
    | split row (char nul)
    | where $it != ""
    | where ((sops -d --output /dev/null $it | complete).exit_code == 0)
  )
  $files | par-each {|file|
    sops updatekeys -y $file
  }
  $files | each {|file|
    git add $file
  }

  ignore
}

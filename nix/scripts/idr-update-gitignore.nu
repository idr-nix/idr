export def main [] {
  let rules = [
    { comment: "# devshell state", rule: "/.data/*" },
    { comment: "# pre-commit configuration", rule: "/.pre-commit-config.yaml" },
    { comment: "# direnv customization", rule: "/.envrc.local" },
    { comment: "# local environment", rule: "/.env" },
    { comment: "# nix build symlinks", rule: "/result" },
    { comment: "# nix build symlinks", rule: "/result-*" },
    { comment: "# nixos test VM", rule: "/*-efi-vars.fd" },
    { comment: "# generated SOPS configuration", rule: "/.sops.yaml" },
    { comment: "# generated documentation", rule: "/docs/generated" },
    { comment: "# mdbook generated website", rule: "/book" },
  ]

  if not (".gitignore" | path exists) {
    touch .gitignore
  }

  let gitignore_content = open .gitignore | lines

  for it in ($rules | enumerate) {
    if $it.item.rule not-in $gitignore_content {
      if $it.index == 0 and ($gitignore_content | length) == 0 {
        echo $it.item.comment | save --append .gitignore
      } else {
        echo $"\n($it.item.comment)" | save --append .gitignore
      }
      echo $"\n($it.item.rule)\n" | save --append .gitignore
    }
  }
}

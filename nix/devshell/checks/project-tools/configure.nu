use std/assert

def main [project_module: path] {
  let machine = "nix/machine/test-machine"
  let secrets = $machine | path join "secrets.enc.json"
  let bootstrap = $env.PRJ_DATA_DIR | path join "machine-host-key/test-machine"
  assert ($bootstrap | path exists) "A new machine needs a bootstrap SOPS identity"
  assert (sops decrypt ($machine | path join "disk-key.enc.json") | from json | get disk_key | is-not-empty)
  assert not ("disk_key" in (open $secrets))

  idr-mk-role test
  let role_id = open nix/role/test/meta.json | get id
  let role_name = $"test-($role_id)"
  assert ($role_id =~ '^[0-9a-f]{12}$')
  assert not ("nix/role/test/secrets.enc.json" | path exists)

  let other_project = $env.PRJ_DATA_DIR | path join "other-role-project"
  mkdir $other_project
  git -C $other_project init
  with-env {PRJ_ROOT: $other_project} { idr-mk-role test }
  mv ($other_project | path join "nix/role") nix/other-roles
  rm -r $other_project
  git add nix/other-roles
  let other_role_id = open nix/other-roles/test/meta.json | get id
  let other_role_name = $"test-($other_role_id)"
  assert not equal $role_id $other_role_id "Same-named roles must have distinct identities"
  open --raw nix/other-roles/test/nixos-module.nix
    | str replace 'config = lib.mkIf cfg.enable {};' 'config = lib.mkIf cfg.enable {
      environment.etc."idr-other-role".text = "other";
    };'
    | save --force nix/other-roles/test/nixos-module.nix

  idr-mk-module test-feature
  let module_files = [
    "nix/test-feature/flake-module.nix"
    "nix/test-feature/nixos-module.nix"
  ]
  assert equal (
    git diff --cached --name-only -- ...$module_files | lines
  ) $module_files "Generated module files must be staged so Nix can discover them"
  let status_before = git status --porcelain
  let invalid = idr-mk-module ../invalid-module | complete
  assert not equal $invalid.exit_code 0 "A module name must not escape its directory"
  assert not ("invalid-module" | path exists)
  assert equal (git status --porcelain) $status_before "An invalid module name must not change the project"

  open --raw nix/test-feature/nixos-module.nix
    | str replace 'config = lib.mkIf (cfgs != {}) {' 'config = lib.mkIf (cfgs != {}) {
      environment.etc = lib.concatMapAttrs (name: cfg: {
        "idr-test-feature-${name}".text = name;
      }) cfgs;'
    | save --force nix/test-feature/nixos-module.nix
  open --raw nix/role/test/nixos-module.nix
    | str replace 'config = lib.mkIf cfg.enable {};' 'config = lib.mkIf cfg.enable {
      idr.test-feature = { first = {}; second = {}; disabled.enable = false; };
    };'
    | save --force nix/role/test/nixos-module.nix
  let feature_state = 'config: {
    roles = builtins.mapAttrs (_: cfg: cfg.enable) config.idr.roles;
    instances = builtins.mapAttrs (_: cfg: cfg.enable) config.idr.test-feature;
    markers = {
      first = config.environment.etc."idr-test-feature-first".text or null;
      second = config.environment.etc."idr-test-feature-second".text or null;
      disabled = config.environment.etc."idr-test-feature-disabled".text or null;
      otherRole = config.environment.etc."idr-other-role".text or null;
    };
  }'
  assert equal (
    nix --offline eval --json '.#nixosConfigurations.test-machine.config' --apply $feature_state | from json
  ) {
    roles: {$role_name: false, $other_role_name: false}
    instances: {}
    markers: {first: null, second: null, disabled: null, otherRole: null}
  } "A discovered module must apply no configuration before instances are declared"

  let role_files = [
    "nix/role/flake-module.nix"
    "nix/role/test/flake-module.nix"
    "nix/role/test/nixos-module.nix"
  ]
  let scaffold_files = $role_files | append $module_files
  for file in $scaffold_files {
    let edited = (open --raw $file) + "\n# Preserve this scaffold customization.\n"
    $edited | save --force $file
  }
  open nix/role/test/meta.json | insert description "Preserve this metadata"
    | save --force nix/role/test/meta.json
  let before = $scaffold_files | append "nix/role/test/meta.json" | each {|file|
    {file: $file, content: (open --raw $file)}
  }
  idr-mk-role test
  idr-mk-module test-feature
  for original in $before {
    assert equal (open --raw $original.file) $original.content "Repeated scaffolding must preserve module and role files and identity"
  }

  let operator = $env.PRJ_DATA_DIR | path join "operator"
  ssh-keygen -q -t ed25519 -f $operator -N "" -C test-operator
  let public = open --raw $"($operator).pub" | str trim
  let age = $public | ssh-to-age | str trim
  let unlock_key = $env.PRJ_DATA_DIR | path join "unlock-server"
  ssh-keygen -q -t ed25519 -f $unlock_key -N "" -C test-unlock-server
  let unlock_public = open --raw $"($unlock_key).pub" | str trim
  let id = open --raw ($machine | path join "configuration.nix")
    | parse --regex 'id = "(?<id>[0-9a-f]{12})"' | get 0.id

  mkdir team nix/testing
  {
    operator: {
      firstName: "Test", lastName: "Operator", mail: "test@example.invalid"
      sshPublicKey: $public, agePublicKey: $age
      groups: [$"host-test-machine-($id)", $"role-($role_name)", $"role-($other_role_name)"]
      sshAccess: {$"test-machine-($id)": {}}
    }
    unlock-server-test: {
      system: true
      groups: [unlock-server]
      sshPublicKey: $unlock_public
      agePublicKey: ($unlock_public | ssh-to-age | str trim)
      hostname: "192.0.2.40"
      port: 64998
    }
  } | to toml | save team/team.toml
  git -C team init
  git -C team add team.toml
  git -C team commit -m "Test operator"

  open --raw $project_module | save nix/testing/flake-module.nix

  let recipients = [$age (open $secrets | get ssh_host_ed25519_key_age_pub_unencrypted | str trim)] | str join ","
  {token: "role data survives recipient rotation"} | to json
    | sops --config /dev/null encrypt --age $recipients --filename-override secrets.enc.json
    | save nix/role/test/secrets.enc.json
  {text: "first line\nsecond line\n"} | to yaml
    | sops --config /dev/null encrypt --age $recipients --filename-override secrets.enc.yaml
    | save "nix/role/test/multi line.enc.yaml"
  open --raw flake.nix
    | str replace 'file+file:///dev/null' 'git+file:///tmp/project/team'
    | save --force flake.nix
  git add flake.nix nix
  nix --offline flake update team
  assert equal (
    nix --offline eval --json '.#nixosConfigurations.test-machine.config' --apply $feature_state | from json
  ) {
    roles: {$role_name: true, $other_role_name: false}
    instances: {first: true, second: true, disabled: false}
    markers: {first: "first", second: "second", disabled: null, otherRole: null}
  } "Each declared module instance must apply its own configuration unless disabled"

  let host_recipient = open $secrets | get ssh_host_ed25519_key_age_pub_unencrypted | str trim
  let recipients_for = {|policy, file|
    $policy.creation_rules | where {|rule| $file =~ $rule.path_regex } | first | get age
  }
  let policy = nix --offline build --no-link --print-out-paths .#idr-sops-config | str trim | open
  assert ($host_recipient in (do $recipients_for $policy "nix/role/test/secrets.enc.json"))
  assert equal (do $recipients_for $policy "nix/other-roles/test/secrets.enc.json") [$age] "A same-named disabled role must not grant the machine access"

  let configuration = open --raw nix/testing/flake-module.nix
  $configuration
    | str replace '${roleName}.enable = true;' '${roleName}.enable = false;'
    | str replace '${otherRoleName}.enable = false;' '${otherRoleName}.enable = true;'
    | save --force nix/testing/flake-module.nix
  assert equal (
    nix --offline eval --json '.#nixosConfigurations.test-machine.config' --apply $feature_state | from json
  ) {
    roles: {$role_name: false, $other_role_name: true}
    instances: {}
    markers: {first: null, second: null, disabled: null, otherRole: "other"}
  } "Same-named roles must be independently enabled"
  let policy = nix --offline build --no-link --print-out-paths .#idr-sops-config | str trim | open
  assert equal (do $recipients_for $policy "nix/role/test/secrets.enc.json") [$age] "Enabling another role ID must not grant access to the local role's secrets"
  assert ($host_recipient in (do $recipients_for $policy "nix/other-roles/test/secrets.enc.json"))
  $configuration | save --force nix/testing/flake-module.nix

  [
    'IDR_USER=operator'
    $'IDR_SOPS_AGE_KEY_CMD="ssh-to-age -i ($operator) -private-key"'
    "IDR_QEMU_EXTRA_OPTIONS_JSON='[\"-enable-kvm\",\"-cpu\",\"host\",\"-smp\",\"4\"]'"
  ] | str join "\n" | save --force .env
}

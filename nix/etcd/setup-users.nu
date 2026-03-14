def checked [operation: string] {
  let result = $in
  if $result.exit_code != 0 {
    print --stderr $result.stderr
    error make {msg: $"etcdctl ($operation) failed"}
  }
  $result.stdout
}

def --wrapped ectl [...args: string] {
  ^etcdctl ...$args | complete | checked ($args | str join " ")
}

def password [credential: string] {
  let value = (open --raw ($env.CREDENTIALS_DIRECTORY | path join $credential)
    | str replace --regex '[\r\n]+$' '')
  # etcdctl's noninteractive password reader consumes one whitespace-delimited token.
  if ($value | is-empty) or ($value =~ '\s') or ($value | str contains (char nul)) {
    error make {msg: $"Password credential ($credential) must be nonempty and contain no whitespace or NUL bytes"}
  }
  $value
}

def set-password [operation: string, user: string, value: string] {
  $value | ^etcdctl user $operation --interactive=false -- $user
    | complete | checked $"user ($operation) ($user)" | ignore
}

# Match etcd's bytewise prefix boundary without decoding that boundary as Unicode.
def prefix-end [key: binary] {
  mut index = ($key | bytes length) - 1
  while $index >= 0 {
    let byte = ($key | bytes at $index..$index | into int)
    if $byte < 255 {
      return ([($key | bytes at 0..<$index) ($byte + 1 | into binary --compact)] | bytes collect)
    }
    $index -= 1
  }
  0x[00]
}

def desired-permission [permission: record] {
  let is_key = ($permission.target | describe) == "string"
  let key = (if $is_key { $permission.target } else { $permission.target.from } | into binary)
  {
    key: (if ($key | is-empty) { 0x[00] } else { $key })
    range_end: (if $permission.prefix {
      prefix-end $key
    } else if $is_key {
      0x[]
    } else {
      $permission.target.to | into binary
    })
    access: $permission.access
    declaration: $permission
  }
}

def stored-permission [permission: record] {
  {
    key: ($permission.key | decode base64)
    range_end: ($permission.range_end? | default "" | decode base64)
    access: ([read write readwrite] | get ($permission.permType? | default 0))
  }
}

def same-range [left: record, right: record] {
  $left.key == $right.key and $left.range_end == $right.range_end
}

def revoke-permission [role: string, permission: record] {
  let key = if $permission.key == 0x[00] { "" } else { $permission.key | decode utf-8 }
  if $permission.range_end == 0x[00] {
    ectl role revoke-permission --from-key -- $role $key | ignore
  } else if $permission.range_end == (prefix-end $permission.key) {
    # --prefix also handles range boundaries that are not valid UTF-8.
    ectl role revoke-permission --prefix -- $role $key | ignore
  } else {
    let end = if ($permission.range_end | is-empty) { [] } else { [($permission.range_end | decode utf-8)] }
    ectl role revoke-permission -- $role $key ...$end | ignore
  }
}

def grant-permission [role: string, permission: record] {
  let flags = if $permission.prefix { ["--prefix"] } else { [] }
  let target = if ($permission.target | describe) == "string" {
    [$permission.target]
  } else {
    [$permission.target.from $permission.target.to]
  }
  ectl role grant-permission ...$flags -- $role $permission.access ...$target | ignore
}

def main [settings: path] {
  let rbac = (open $settings)
  let root_password = (password root-password)
  # Validate all credentials before changing the cluster.
  let users = ($rbac.users | transpose name value | each {|user|
    {name: $user.name, roles: $user.value.roles, password: (password $user.value.password)}
  })

  $env.ETCDCTL_USER = "root"
  $env.ETCDCTL_PASSWORD = $root_password
  # The client tolerates disabled authentication; enabled clusters require root here.
  let status = (ectl auth status | from json)
  if not ($status.enabled? | default false) {
    let users = (ectl user list | from json | get users? | default [])
    if "root" not-in $users {
      set-password add root $root_password
    }
    let roles = (ectl role list | from json | get roles? | default [])
    if "root" not-in $roles {
      ectl role add root | ignore
    }
    let root_roles = (ectl user get root | from json | get roles? | default [])
    if "root" not-in $root_roles {
      ectl user grant-role root root | ignore
    }
    ectl auth enable | ignore
  }

  let existing_users = (ectl user list | from json | get users? | default [])
  let existing_roles = (ectl role list | from json | get roles? | default [])

  for user in ($existing_users | where {|user| $user != "root" and $user not-in $rbac.users }) {
    ectl user delete -- $user | ignore
  }
  for role in ($existing_roles | where {|role| $role != "root" and $role not-in $rbac.roles }) {
    ectl role delete -- $role | ignore
  }

  for role in ($rbac.roles | transpose name value) {
    if $role.name not-in $existing_roles {
      ectl role add -- $role.name | ignore
    }
    let desired = ($role.value.permissions | each {|permission| desired-permission $permission })
    let current = (ectl role get -- $role.name | from json | get perm? | default []
      | each {|permission| stored-permission $permission })

    for permission in $current {
      if not ($desired | any {|candidate| same-range $candidate $permission }) {
        revoke-permission $role.name $permission
      }
    }
    for permission in $desired {
      if not ($current | any {|candidate|
        (same-range $candidate $permission) and $candidate.access == $permission.access
      }) {
        # Granting an existing range replaces its access mode in place.
        grant-permission $role.name $permission.declaration
      }
    }
  }

  for user in $users {
    if $user.name not-in $existing_users {
      set-password add $user.name $user.password
    } else {
      # Each user may inspect itself, even without any assigned roles.
      let check = (with-env {ETCDCTL_USER: $user.name, ETCDCTL_PASSWORD: $user.password} {
        ^etcdctl user get -- $user.name | complete
      })
      if $check.exit_code != 0 {
        if $check.stderr =~ 'authentication failed, invalid user ID or password' {
          set-password passwd $user.name $user.password
        } else {
          $check | checked $"checking password for ($user.name)" | ignore
        }
      }
    }

    let current_roles = (ectl user get -- $user.name | from json | get roles? | default [])
    for role in ($current_roles | where {|role| $role not-in $user.roles }) {
      ectl user revoke-role -- $user.name $role | ignore
    }
    for role in ($user.roles | uniq | where {|role| $role not-in $current_roles }) {
      ectl user grant-role -- $user.name $role | ignore
    }
  }
  print "Reconciled etcd users and roles."
}

## Runtime secrets

IDR uses [sops-nix](https://github.com/Mic92/sops-nix) to read encrypted secrets
and can generate configuration files from them at runtime.

Avoid making service startup depend on external provisioning. For example, issue
and renew certificates in a controlled environment such as CI, and store the
certificates and private keys in SOPS. Production and local VMs can then use the
same certificates without requiring issuance at boot.

The examples below belong in a role or machine's NixOS configuration, with
`config` and `pkgs` available as module arguments.

### Read a SOPS secret

First, create an encrypted file and grant access as described in
[role secrets](../../docs/mk-role.md).

For example, to read `api_token` from an adjacent `secrets.enc.json`:

```nix
idr.secrets-source.api-token = {
  sopsFile = ./secrets.enc.json;
  key = "api_token";
};
sops.secrets.api-token.format = "json";
```

Set the JSON format explicitly, since sops-nix defaults to YAML. If the key in the
file matches the source name, you can omit `key`.

### Generate files from secrets

To generate a file, list its input secrets under `secrets`. These references can
point to SOPS sources or other generated files.

For example, expose `api-token` as `TOKEN` and use it in a template:

```nix
idr.secrets-source.auth-header = {
  secrets.TOKEN = config.idr.secrets.api-token;
  template = "Authorization: Bearer $TOKEN";
};
```

Templates use `envsubst` to replace only the declared variables. Values are
inserted verbatim, so use a script when the output format needs escaping.
For example, this Nushell script creates a JSON file:

```nix
idr.secrets-source.app-config = {
  secrets.TOKEN = config.idr.secrets.api-token;
  exec = "${pkgs.writers.writeNu "app-config" ''
    {token: $env.TOKEN} | to json
  ''}";
};
```

`exec` runs through Bash; here it invokes the Nushell script, whose stdout becomes
the secret file. A generator can instead write to the path in `$out` (`$env.out`
in Nushell); that file takes precedence over stdout.

If the application reads secrets from environment variables, omit both
`template` and `exec` to generate a systemd `EnvironmentFile`:

```nix
idr.secrets-source.app-env.secrets.API_TOKEN = config.idr.secrets.api-token;
```

### References and permissions

Use `top.idr-lib.types.secret` for module options that accept secret references.

Use `config.idr.secrets.<name>` to access a declared secret:

| Field | Purpose |
|---|---|
| `path` | Runtime file path to pass to the application. |
| `group` | Group with read access to the file. |
| `reloadTarget` | Systemd target for propagating reloads. |
| `restartTarget` | Systemd target for propagating restarts. |

Files are owned by root with mode `0440` and a group for each secret.

When a module option accepts an IDR secret reference, such as the certificate
options in [LDAP](../ldap/README.md), pass the whole reference.

### Connect a service

For example, extend an existing `my-app` service to read the generated `app-env`
file and restart when its input secrets change:

```nix
systemd.services.my-app = let
  secret = config.idr.secrets.app-env;
in {
  wants = [secret.restartTarget];
  after = [secret.restartTarget];
  partOf = [secret.restartTarget];
  serviceConfig.EnvironmentFile = secret.path;
};
```

An `EnvironmentFile` change requires a restart.

If the application reads the file itself, give it read access by adding
`secret.group` to its `serviceConfig.SupplementaryGroups`. If it can reread the
file on reload, replace `restartTarget` with `reloadTarget` in the example and
add this to the service definition:

```nix
unitConfig.ReloadPropagatedFrom = [secret.reloadTarget];
```

Changing only a template or generator does not trigger these targets. Restart or
reload the service after deployment in that case.

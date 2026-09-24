## Service environments

`idr.systemd.services.<name>.environment` sets environment variables of an existing
systemd service. Values can be strings, numbers, booleans, or
[runtime secret](../secrets/README.md) references:

```nix
idr.systemd.services.my-app.environment = {
  API_URL = "https://example.com";
  API_TOKEN = config.idr.secrets.api-token;
  WORKERS = 4;
  DEBUG = false;
};
```

Plain values go into the unit's `Environment`. Secret values are written at runtime
to a generated `EnvironmentFile`, with trailing newlines removed, so they don't
appear in the Nix store. Booleans become `true` or `false`.

The service starts after IDR's secrets are generated. When a secret value changes,
the service is reloaded if it defines a reload command, otherwise restarted. Set
`reloadOnEnvironmentChange` to choose explicitly:

```nix
idr.systemd.services.my-app.reloadOnEnvironmentChange = false;
```

The module is imported into [NixOS containers](../preset/README.md#nixos-containers)
with the other IDR modules.

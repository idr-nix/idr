## Certificates

Manage certificates in the role that uses them. Before issuing, configure the
role's [secret recipients](../../../docs/mk-role.md#optional-secrets).

Add a `perSystem` definition to the role's `flake-module.nix`. Include the role ID
in certificate names to avoid collisions between projects. For example:

```nix
perSystem = {...}: {
  idr.certs."tls-${(lib.importJSON ./meta.json).id}" = {
    sopsFile = ./certs.enc.yaml;
    domains = ["example.com" "*.example.com"];
    email = "ops@example.com";
    legoFlags = ["--dns" "cloudflare"];
    envRename.CLOUDFLARE_DNS_API_TOKEN = "CLOUDFLARE_PROJECT_TOKEN";
  };
};
```

`legoFlags` selects the challenge provider and other [Lego](https://go-acme.github.io/lego/)
options. `envRename` is optional; it maps the provider's variable names to variables in the calling
environment, allowing different certificates to use different provider accounts.
In this example, supply `CLOUDFLARE_PROJECT_TOKEN` when running the updater.

### Issue and update

From the development shell, run:

```sh
idr-update-certs
```

The command issues missing certificates and replaces certificates issued at least
30 days ago. Pass certificate names to select only those certificates:

```sh
idr-update-certs "tls-<id>"
```

Certificates, private keys, and combined PEM files are saved in the configured
SOPS JSON or YAML files. Certificates can share a file; unrelated entries are
preserved. Changed files are staged in Git for review.

Lego stores its account and certificate state under `$PRJ_DATA_DIR/lego`
(normally `.data/lego`). Preserve that directory between runs to reuse accounts.
`LEGO_PATH` can select a different directory.

### Run in CI

Schedule the following command, for example daily, with the SOPS decryption
identities and DNS-provider credentials available in the environment:

```sh
nix develop -c idr-update-certs
```

Shell startup generates the SOPS recipient policy. Have CI commit the staged
certificate changes or open a pull request when files changed. Deploy the updated
configuration to load the certificates into services.

### Use a certificate

In the role's `nixos-module.nix`, register the same certificate name:

```nix
idr.certs-source."tls-${(lib.importJSON ./meta.json).id}" = ./certs.enc.yaml;
```

`config.idr.certs.<name>` provides three [secret references](../../secrets/README.md):

| Field | Content |
|---|---|
| `cert` | Certificate chain |
| `certKey` | Private key |
| `certPem` | Combined private key and certificate chain |

For example, configure an existing LDAP instance with:

```nix
idr.ldap.main.cert = config.idr.certs."tls-${(lib.importJSON ./meta.json).id}".cert;
idr.ldap.main.certKey = config.idr.certs."tls-${(lib.importJSON ./meta.json).id}".certKey;
```

Services receive paths, access groups, and reload/restart targets through these
references. Issuance runs on the operator machine or in CI; servers and local VMs
use the deployed certificates.

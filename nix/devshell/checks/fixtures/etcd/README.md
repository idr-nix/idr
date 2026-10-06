These are public credentials for the etcd documentation tests. They must never
protect real data. The encrypted JSON includes synthetic WireGuard keys,
pairwise preshared keys, individual HTTPS certificates, and application passwords.
It uses the deliberately public age identity in `../runtime-secrets/key.txt`.
The public CA signs only these test certificates; they expire in 2126.
`updated.enc.json` changes only the application's password.

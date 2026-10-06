"""Type the runtime-decrypted fixture password without putting it in argv/logs."""

import subprocess


password = subprocess.check_output(
    [
        "sops", "--decrypt", "--extract", '["root_password"]',
        "nix/machine/test-machine/secrets.enc.json",
    ],
).rstrip(b"\n")
subprocess.run(
    ["xdotool", "type", "--clearmodifiers", "--file", "-"], input=password, check=True,
)
subprocess.run(["xdotool", "key", "Return"], check=True)

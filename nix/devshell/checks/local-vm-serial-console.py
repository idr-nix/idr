"""Drive the documented serial login without logging terminal passwords."""

import os
import subprocess

import pexpect


password = subprocess.check_output(
    [
        "sops", "--decrypt", "--extract", '["root_password"]',
        "nix/machine/test-machine/secrets.enc.json",
    ],
    text=True,
).rstrip("\n")

for escape, key, label in [(None, "z", "Ctrl-Z"), ("ctrl-]", "]", "Ctrl-]")]:
    environment = os.environ.copy()
    environment.pop("IDR_SERIAL_ESCAPE", None)
    if escape is not None:
        environment["IDR_SERIAL_ESCAPE"] = escape
    console = pexpect.spawn(
        "idr-serial", ["test-machine"], env=environment, encoding="utf-8", timeout=60,
    )
    step = "connect"
    try:
        console.expect_exact(f"Press {label} to disconnect.")
        step = "login prompt"
        console.sendline("")
        console.expect(r"test-machine login: ")
        console.sendline("root")
        step = "password prompt"
        console.expect(r"Password:")
        console.sendline(password)
        step = "root shell"
        console.expect(r"root@test-machine[^\r\n]*[#]")
        step = "guest command"
        console.sendline("printf '__IDR_SERIAL_GUEST__:%s\\n' \"$(hostname)\"")
        console.expect_exact("__IDR_SERIAL_GUEST__:test-machine")
        console.expect(r"root@test-machine[^\r\n]*[#]")
        step = "logout"
        console.sendline("exit")
        console.expect(r"test-machine login: ")
        step = "disconnect"
        console.sendcontrol(key)
        console.expect(pexpect.EOF)
        console.close()
        if console.exitstatus != 0:
            raise RuntimeError("console did not exit successfully")
    except Exception:
        # Pexpect exceptions otherwise include the terminal buffer, which can
        # contain credentials when diagnosing a broken login/echo sequence.
        console.close(force=True)
        raise SystemExit(f"Serial {label} session failed at {step}") from None
    print(f"Serial root login and {label} disconnect succeeded")

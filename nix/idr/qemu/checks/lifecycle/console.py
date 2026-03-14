"""Check the real console clients without an interactive terminal or GUI."""

import os
import pty
import select
import socket
import subprocess
import sys
import termios
import time

with socket.socket(socket.AF_UNIX) as vnc:
    vnc.settimeout(5)
    vnc.connect(sys.argv[1])
    assert vnc.recv(12) == b"RFB 003.008\n"

for label, escape in (("ctrl-z", b"\x1a"), ("ctrl-]", b"\x1d")):
    master, slave = pty.openpty()
    client = subprocess.Popen(
        ["idr-test", "idr-serial", "lifecycle"],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env={**os.environ, "IDR_SERIAL_ESCAPE": label},
        start_new_session=True,
    )
    os.close(slave)
    try:
        output = b""
        deadline = time.monotonic() + 10
        while b"to disconnect." not in output:
            assert time.monotonic() < deadline, output
            readable, _, _ = select.select([master], [], [], 1)
            if readable:
                output += os.read(master, 4096)
        # The connection message precedes exec; wait for socat to enter raw mode.
        while termios.tcgetattr(master)[3] & termios.ICANON:
            assert time.monotonic() < deadline
            time.sleep(0.01)
        os.write(master, escape)
        assert client.wait(timeout=5) == 0
    finally:
        if client.poll() is None:
            client.kill()
            client.wait()
        os.close(master)

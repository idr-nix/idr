"""Exercise the installer command and adapter without accessing real target disks."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys


def external_command(name, args):
    """Record and answer the external transport boundary of the real Nushell script."""
    with Path(os.environ["CALLS"]).open("a") as output:
        output.write(json.dumps([name, *args]) + "\n")
    if name == "nix":
        if args[:1] == ["eval"]:
            print(Path(os.environ["TARGET"]).read_text())
        elif args[:2] == ["flake", "lock"]:
            Path(args[args.index("--output-lock-file") + 1]).write_text("{}")
        else:
            raise AssertionError(args)
    elif name == "ssh":
        if "-G" in args:
            print("host rescue\nhostname 127.0.0.1\nuser root\nport 2223")
        else:
            command = shlex.split(args[-1])
            if command[:1] == ["cat"]:
                print("ID=nixos")
            elif command[:1] == ["swapon"]:
                pass
            elif command[:1] == ["lsblk"]:
                print(json.dumps({"blockdevices": [] if os.environ.get("MISSING_DISK") else [{
                    "name": "/dev/installation-test", "maj:min": "8:0", "type": "disk",
                    "fstype": "ext4", "mountpoints": ["/mnt"],
                }]}))
            else:
                raise AssertionError(command)
    elif name == "nixos-anywhere":
        directory = Path(os.environ["TMPDIR"]) / "installation"
        Path(os.environ["INSTALLATION"]).write_text(json.dumps({
            "args": args,
            "target": json.loads((directory / "target.json").read_text()),
        }))
        sys.exit(int(os.environ.get("INSTALL_STATUS", "0")))
    elif name != "git":
        raise AssertionError((name, args))


if len(sys.argv) > 1:
    external_command(sys.argv[1], sys.argv[2:])
    sys.exit(0)

work = Path.cwd()
operations = work / "operations"
paths = json.loads(Path(os.environ["SCRIPT_PATHS"]).read_text())


def adapter(script, expected, succeeds=True, **overrides):
    operations.unlink(missing_ok=True)
    result = subprocess.run([paths[script]], env=dict(os.environ, OPERATIONS=str(operations), **overrides),
                            text=True, capture_output=True)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
    assert operations.read_text().splitlines() == expected, result.stdout + result.stderr


# Both upstream nixos-anywhere execution paths must use only disko's mount action.
adapter("mountScript", ["mount"])
adapter("mountScriptNoDeps", ["mountNoDeps"])
adapter("mountScript", ["mount"], succeeds=False, mount_STATUS="7")
adapter("mountScriptNoDeps", ["mountNoDeps"], succeeds=False, mountNoDeps_STATUS="7")
# Retain the default installation's best-effort format and ordinary-failure fallback.
adapter("diskoScript", ["format"])
adapter("diskoScript", ["format", "wipe"], format_STATUS="7")
adapter("diskoScript", ["format"], succeeds=False, format_STATUS="130")

project = work / "project"
data = project / ".data"
machine = project / "nix/machine/test-machine"
machine.mkdir(parents=True)
data.mkdir()
(machine / "configuration.nix").write_text("{}")
target = work / "target.json"
target.write_text(json.dumps({
    "hostname": "rescue", "sshUser": "root", "sshOpts": [], "fastConnection": False,
    "preFormatFiles": {}, "postFormatFiles": {}, "hostId": None, "qemu": None,
    "sourceSopsFile": str(machine / "secrets.enc.json"),
    "projectHash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    "disks": ["/dev/installation-test"], "sshHostPublicKey": None,
}))
calls = work / "calls.jsonl"
installation = work / "installation.json"
bin_directory = work / "bin"
bin_directory.mkdir()
for command in ["nix", "ssh", "git", "nixos-anywhere"]:
    executable = bin_directory / command
    executable.write_text("#!" + sys.executable + "\n"
                          "import runpy, sys\nsys.argv[1:1] = [" + repr(command) + "]\n"
                          "runpy.run_path(" + repr(__file__) + ", run_name='__main__')\n")
    executable.chmod(0o755)


def cli(options, error=None, **overrides):
    calls.unlink(missing_ok=True)
    installation.unlink(missing_ok=True)
    env = dict(os.environ, PRJ_ROOT=str(project), PRJ_DATA_DIR=str(data),
               TARGET=str(target), CALLS=str(calls), INSTALLATION=str(installation),
               PATH=str(bin_directory) + os.pathsep + os.environ["PATH"], **overrides)
    result = subprocess.run(["nu", "--no-config-file", "--no-std-lib", "--no-history",
                             str(Path(os.environ["SCRIPT_SOURCE"]) / "idr-anywhere.nu"),
                             "test-machine", "-n", *options], env=env,
                            stdin=subprocess.DEVNULL, text=True, capture_output=True)
    output = result.stdout + result.stderr
    if error is None:
        assert result.returncode == 0, output
        captured = json.loads(installation.read_text())
    else:
        assert result.returncode != 0 and error in output, output
        captured = None
    assert not list(data.glob("idr-disko-files-*")), "temporary installation files leaked"
    return captured


def values(args, option):
    return [args[index + 1] for index, value in enumerate(args) if value == option]


cli([], error="Missing confirmations: WIPE_ALL_DISKS,WIPE_NIXOS")
cli(["--allow", "WIPE_ALL_DISKS"], error="Missing confirmations: WIPE_NIXOS")
assert not installation.exists()

for extra in [[], ["--phases", "disko,install"], ["--phases", "disko"]]:
    captured = cli(["--disko-mode", "mount", *extra])
    assert values(captured["args"], "--disko-mode") == ["mount"]
    assert captured["target"]["diskoMode"] == "mount"
    assert values(captured["args"], "--phases") == [extra[1] if extra else "disko,install"]
    assert "--generate-hardware-config" not in captured["args"], "recovery VM hardware captured"
    assert "WIPE" not in json.dumps(captured)
    assert not (machine / "facter.json").exists()

captured = cli(["--allow", "WIPE_ALL_DISKS,WIPE_NIXOS"])
assert values(captured["args"], "--disko-mode") == ["disko"]
assert captured["target"]["diskoMode"] == "disko"
assert "--phases" not in captured["args"]
assert values(captured["args"], "--generate-hardware-config") == ["nixos-facter"]

captured = cli(["--disko-mode", "mount", "--generate-hardware-config", "nixos-facter", "/explicit.json"])
assert values(captured["args"], "--generate-hardware-config") == ["nixos-facter"]
assert "/explicit.json" in captured["args"]
cli(["--disko-mode", "format"], error="Unsupported disko mode")
assert not calls.exists(), "invalid mode reached secrets or the target"
cli(["--disko-mode", "mount"], error="was not found", MISSING_DISK="1")
assert not installation.exists(), "missing target disk reached the installer"
print("Mount mode preserves the selected mount action, refuses unsafe fallback, skips wipe confirmations and recovery hardware capture.")

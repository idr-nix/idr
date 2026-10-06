top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.team-ssh-expiry = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./team-ssh-fixture.nix top)];
      name = "team-ssh-expiry";

      testScript = ''
        start_all()
        machine.wait_for_unit("sshd.service")
        machine.succeed("date -s '2027-09-07 17:00:00 UTC'")

        with subtest("authenticate permanent and expiring team grants before expiry"):
            assert machine.succeed("ssh permanent whoami").strip() == "root"
            assert machine.succeed("ssh temporary whoami").strip() == "root"
            machine.succeed("ssh -MNf -S /run/team-ssh-control temporary")
            machine.succeed(
                "timeout 120 ssh temporary 'touch /run/team-ssh-session-started; "
                "while ! test -e /run/team-ssh-session-release; do sleep 0.1; done; "
                "printf continued' >/run/team-ssh-session-result 2>/run/team-ssh-session-error &"
            )
            machine.wait_until_succeeds("test -e /run/team-ssh-session-started")

        with subtest("deny new authentication after expiry without another deployment"):
            generation = machine.succeed("readlink /run/current-system").strip()
            machine.succeed("date -s '2027-09-07 18:00:01 UTC'")
            status, output = machine.execute("ssh temporary whoami 2>&1")
            assert status == 255 and "Permission denied" in output, output
            assert machine.succeed("ssh permanent whoami").strip() == "root"
            assert machine.succeed("readlink /run/current-system").strip() == generation

        with subtest("retain existing sessions and multiplexed connections"):
            machine.succeed("touch /run/team-ssh-session-release")
            machine.wait_until_succeeds("test \"$(cat /run/team-ssh-session-result)\" = continued")
            assert machine.succeed("ssh -S /run/team-ssh-control temporary whoami").strip() == "root"
            machine.succeed("ssh -S /run/team-ssh-control -O exit temporary")
      '';
    };
  };
}

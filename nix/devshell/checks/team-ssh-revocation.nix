top: {lib, ...}: {
  perSystem = {pkgs, ...}: {
    checks.team-ssh-revocation = pkgs.testers.runNixOSTest {
      imports = [(lib.modules.importApply ./team-ssh-fixture.nix top)];
      name = "team-ssh-revocation";

      nodes.machine.specialisation.revoked.configuration.idr.test.revokedMembers = ["Temporary"];

      testScript = ''
        start_all()
        machine.wait_for_unit("sshd.service")
        machine.succeed("date -s '2027-09-07 17:00:00 UTC'")

        with subtest("authenticate both members before updating the team"):
            temporary_user, permanent_user = machine.succeed(
                "set -e; ssh temporary whoami; ssh permanent whoami"
            ).splitlines()
            assert temporary_user.strip() == "root"
            assert permanent_user.strip() == "root"

        with subtest("apply the machine configuration with the member removed"):
            machine.succeed(
                "/run/current-system/specialisation/revoked/bin/switch-to-configuration test",
                timeout=180,
            )
            machine.wait_for_unit("sshd.service")

        with subtest("deny the removed member while retaining the other grant"):
            status, output = machine.execute("ssh temporary whoami 2>&1")
            assert status == 255 and "Permission denied" in output, output
            # The expiring grant is still well within its validity period: its
            # removal, not the server clock, must account for the denial.
            permanent_user = machine.succeed(
                "set -e; ssh permanent whoami; "
                "test $(date +%s) -lt $(date -d '2027-09-07 18:00:00 UTC' +%s)"
            ).strip()
            assert permanent_user == "root"
      '';
    };
  };
}

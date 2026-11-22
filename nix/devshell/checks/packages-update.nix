_: {
  perSystem = {pkgs, ...}: let
    # Records the update and fails for the package named in FAIL. With
    # BARRIER set, alpha and beta each wait for the other to start.
    update = name: partner:
      pkgs.writeShellScript "update-${name}" ''
        echo "update ${name}" >> "$CALLS"
        echo "output of ${name}"
        if [ -n "''${BARRIER:-}" ] && [ -n "${partner}" ]; then
          touch "$BARRIER/${name}"
          for _ in $(seq 50); do
            [ -e "$BARRIER/${partner}" ] && break
            sleep 0.1
          done
          [ -e "$BARRIER/${partner}" ] || exit 1
        fi
        [ "${name}" != "$FAIL" ]
      '';
    nix = pkgs.writeShellScriptBin "nix" ''
      echo "nix $*" >> "$CALLS"
    '';
    command = import ../../idr/packages/command.nix {
      inherit pkgs;
      packages = {
        alpha = {
          update = "${update "alpha" "beta"}";
          build = true;
        };
        beta = {
          update = "${update "beta" "alpha"}";
          build = true;
        };
        gamma = {
          update = "${update "gamma" ""}";
          build = true;
        };
        delta = {
          update = "${update "delta" ""}";
          build = false;
        };
      };
    };
  in {
    checks.packages-update =
      pkgs.runCommand "packages-update" {
        nativeBuildInputs = [command nix];
      } ''
        export PRJ_ROOT="$PWD" CALLS="$PWD/calls" FAIL=gamma
        expect_calls() {
          diff -u <(sort) <(sort calls)
          rm calls
        }

        # Every package; a failed update skips only its build.
        if idr-update-packages > output 2>&1; then
          echo "expected a failure" >&2
          exit 1
        fi
        grep -q 'Could not update: gamma' output
        grep -q 'output of delta' output
        expect_calls <<'EOF'
        update alpha
        nix build --no-link --print-build-logs .#alpha
        update beta
        nix build --no-link --print-build-logs .#beta
        update gamma
        update delta
        EOF

        idr-update-packages delta
        expect_calls <<'EOF'
        update delta
        EOF

        # alpha and beta only succeed when they run at the same time.
        export BARRIER="$PWD/parallel"
        mkdir "$BARRIER"
        idr-update-packages --threads 2 alpha beta
        rm -r calls "$BARRIER"/*
        if idr-update-packages -t 1 alpha beta > output 2>&1; then
          echo "expected one thread to run alpha and beta in turn" >&2
          exit 1
        fi
        rm calls
        unset BARRIER

        if idr-update-packages alpha epsilon > output 2>&1; then
          echo "expected a failure" >&2
          exit 1
        fi
        grep -q 'Unknown packages: epsilon' output
        test ! -e calls

        touch "$out"
      '';
  };
}

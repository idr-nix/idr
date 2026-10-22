{reminders}: {pkgs, ...}: let
  settings = pkgs.writeText "idr-reminders.json" (builtins.toJSON reminders);
  command = pkgs.writers.writeNuBin "idr-reminders" {
    makeWrapperArgs = ["--set" "IDR_REMINDERS_FILE" settings];
  } (builtins.readFile ../../scripts/idr-reminders.nu);
in {
  packages = [command];

  devshell.startup.idr-reminders.text = ''
    idr_due_reminders="$(${command}/bin/idr-reminders --due --full)"
    if [[ -n "$idr_due_reminders" ]]; then
      printf 'IDR reminders need review (idr-reminders --due):\n%s\n' "$idr_due_reminders" >&2
    fi
    unset idr_due_reminders
  '';
}

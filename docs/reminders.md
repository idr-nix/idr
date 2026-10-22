## Review reminders

Declare reminders in a flake module:

```nix
_: {
  idr.reminders.dependency-review = {
    description = ''
      Review the dependency update and run its regression checks.
    '';
    lastReviewedAt = 1792638790; # Unix seconds
    reviewIntervalSec = 7 * 24 * 60 * 60;
  };
}
```

Due reminders appear on devshell entry. Use `idr-reminders` to inspect them:

```sh
idr-reminders                   # All names, next review dates, and status
idr-reminders --full             # Include full descriptions (-f)
idr-reminders dependency-review  # One reminder with its description
idr-reminders --due              # Only reminders needing review
idr-reminders --json             # Complete records keyed by name
```

After reviewing, set `lastReviewedAt` to the output of `date +%s`.

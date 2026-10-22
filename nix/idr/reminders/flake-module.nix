_: {
  config,
  lib,
  ...
}: {
  options.idr.reminders = lib.mkOption {
    default = {};
    description = "Periodic review reminders, keyed by name.";
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        description = lib.mkOption {
          type = lib.types.lines;
          description = "Plain-text reminder description; may contain multiple lines.";
        };
        lastReviewedAt = lib.mkOption {
          type = lib.types.ints.unsigned;
          description = "Unix timestamp in seconds of the last actual review.";
        };
        reviewIntervalSec = lib.mkOption {
          type = lib.types.ints.positive;
          description = "Number of seconds between reviews.";
        };
      };
    });
  };

  config.perSystem.devshells.default = lib.modules.importApply ./devshell.nix {
    inherit (config.idr) reminders;
  };
}

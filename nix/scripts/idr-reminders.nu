def review-date [timestamp: int] {
  $timestamp | into datetime --format "%s" | date to-timezone local | format date "%Y-%m-%d %H:%M:%S %:z"
}

# List periodic review reminders. Selecting a name shows its full details.
def main [
  name?: string # Select one reminder
  --full(-f) # Include full plain-text descriptions
  --json # Output complete records keyed by name, including review timing
  --due # Show only reminders whose next review time has arrived
] {
  let configured = open $env.IDR_REMINDERS_FILE
  if $name != null and $name not-in ($configured | columns) {
    print --stderr $"Unknown reminder '($name)'. Run idr-reminders to list reminders."
    exit 1
  }

  let now = date now | format date "%s" | into int
  let reminders = $configured | transpose name value | sort-by name | each {|entry|
    let next_review = $entry.value.lastReviewedAt + $entry.value.reviewIntervalSec
    {
      name: $entry.name
      value: ($entry.value | merge {
        nextReviewAt: $next_review
        needsReview: ($now >= $next_review)
      })
    }
  } | where {|entry|
    ($name == null or $entry.name == $name) and (not $due or $entry.value.needsReview)
  }

  if $json {
    $reminders | reduce --fold {} {|entry, result|
      $result | insert $entry.name $entry.value
    } | to json --indent 2 | print
    return
  }

  let blocks = $reminders | each {|entry|
    let reminder = $entry.value
    let status = if $reminder.needsReview { "DUE" } else { "scheduled" }
    let next = review-date $reminder.nextReviewAt
    if $full or $name != null {
      [
        $"Reminder: ($entry.name)"
        $"Next review: ($next) [($status)]"
        ""
        "Description:"
        $reminder.description
      ] | str join "\n"
    } else {
      $"($entry.name)  Next review: ($next) [($status)]"
    }
  }
  if not ($blocks | is-empty) {
    print ($blocks | str join (if $full or $name != null { "\n\n----------------------------------------\n\n" } else { "\n" }))
  }
}

# Secret Santa

A macOS Swift script that generates Secret Santa assignments using randomized
DFS, keeps yearly history, and sends individual emails through Apple Mail.
Each participant gives and receives once. Matches exclude self-assignment,
reciprocal pairs, shared exclusion groups, and the recipient from each person's
most recent recorded participation.

## Setup

You need Swift (`swift --version`) and, for sending, a dedicated account configured
in Apple Mail. Keep `send.applescript` beside `santa.swift`. No third-party
packages are required.

Copy `templates/config.json`, `templates/people.csv`, and `templates/groups.csv`
into the folder containing `santa.swift`. Customize these local copies. If you
have previous assignments to import, also copy and customize `templates/history.csv`;
otherwise omit it. The sample participants and history are illustrative.

| File | Columns | Purpose |
| --- | --- | --- |
| `people.csv` | `id,name,email,phone,active` | Participants and current contact details; phone is optional. |
| `groups.csv` | `group,person_id` | One row per exclusion-group membership. |
| `history.csv` (optional) | `year,giver_id,recipient_id` | Import complete assignments from previous years. |

Keep IDs stable when changing names or emails. Set `active` to `false` instead
of deleting former participants. Use lowercase `true` or `false` for `active`.
Active participants need a nonempty email address, including with `--no-email`.
At least three active participants are needed to generate a draw, and the
exclusions must allow a valid assignment.

A person can belong to multiple groups; sharing any group prevents a match in
either direction. If there are no exclusions, keep `groups.csv` with just its
header. Each imported historical year must be complete: every participant gives
and receives exactly once, and all IDs must exist in `people.csv`.

Configure all four fields in `config.json`:

- `drawYear`: a four-digit integer specifying the year to generate, reuse,
  regenerate, and send.
- `senderEmail`: replace `secret-santa@example.com` with an address belonging
  to exactly one enabled Apple Mail account before sending.
- `subjectTemplate` and `bodyTemplate`: email wording. Supported placeholders are
  `{year}`, `{giver}`, and `{recipient}`. Both templates receive
  these values. The subject must be nonempty and the body must contain
  `{recipient}`. Include event details directly in `bodyTemplate`. JSON uses
  `\n` for a newline.

Local configuration, participant CSVs, generated history, and backups are
ignored by Git. Templates and test fixtures remain tracked.

## Usage

Run these commands from the folder containing your script:

```sh
swift santa.swift
swift santa.swift --show-matches
swift santa.swift --no-email
swift santa.swift --regenerate-matches --show-matches --no-email
```

Every run validates configuration and CSV inputs, imports and merges history,
generates matches if the configured year has no saved draw, and saves
automatically. A successful draw reports the match count; assignments stay hidden
unless `--show-matches` is supplied. `--no-email` still saves history and matches.

Existing matches are reused unless `--regenerate-matches` is supplied. Changes
to active flags or exclusion groups do not change a saved draw. Emails use current
names and addresses from `people.csv`, including for saved participants who have
since become inactive.

Without `--no-email`, the script validates sender and pending recipient email
address formats, prepares pending emails, and asks whether to send. For example:

```text
3 assignment emails are ready to send to:
- Ana
- Bruno
- Carla

Send these emails from santa@example.com? [y/N]
```

These are the email recipients, not their gift assignments. Apple Mail is contacted
and the enabled sender account checked only after confirmation. Only `y` or `yes`
(case insensitive, with surrounding whitespace ignored) proceeds; blank input,
EOF, and other responses cancel sending.
Declining leaves the saved matches available for a later run. If all emails were
already submitted, there is no sending prompt. Email subjects and bodies are not
printed. Allow control of Mail if macOS requests it.

The flags can be combined in any order:

| Flag | Behavior |
| --- | --- |
| `--show-matches` | Display the generated or existing saved assignments. |
| `--no-email` | Save matches and stop without checking Mail, prompting, or sending. |
| `--regenerate-matches` | Replace the configured year's draw using current active participants and exclusions, and clear its submission records. |

Regeneration makes everyone in the new draw eligible to receive another email,
even if an earlier assignment was already sent. Sending still requires confirmation.
A fresh randomized draw may produce the same assignments. Failed matching leaves
the previous history intact. Target-year CSV assignments are skipped during
regeneration; remove outdated target-year rows from `history.csv` before subsequent
normal runs to avoid conflicting imports. Regeneration replaces only the configured
year; the normal CSV import can still add historical records for other years.

The old `--send` flag is replaced by the default workflow. `--no-sending` has
been renamed to `--no-email`; neither old flag is accepted.

## History and recovery

Keep `history.json`: it stores assignments and email submission progress.
Updates preserve the previous version in `history.json.bak`; this is a rolling
backup, including updates after individual email submissions. Identical CSV history
imports are harmless; conflicting imports are rejected.

Each successful submission is recorded, so reruns skip those emails. If sending
fails, check Mail before retrying: a message may have been submitted before its
status could be saved. Submission does not confirm delivery.

## Verification

```sh
swift Tests/run.swift
```

Tests use isolated copies of `Tests/Fixtures` and fake email helpers. They do not
change your participant data or send real emails.

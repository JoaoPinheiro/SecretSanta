# Secret Santa

A macOS Swift script that generates Secret Santa assignments using randomized
DFS, keeps yearly history, and sends individual emails through Apple Mail.
Each participant gives and receives once. Matches exclude self-assignment,
reciprocal pairs, shared exclusion groups, and the recipient from each person's
most recent recorded participation.

## Setup

You need Swift (`swift --version`) and, for sending, a dedicated account configured
in Apple Mail. No third-party packages are required.

Keep `santa.swift`, `send.applescript`, and your CSV files in the same folder.
Use the included CSVs as templates:

| File | Columns | Purpose |
| --- | --- | --- |
| `people.csv` | `id,name,email,phone,active` | Participants and current contact details; phone is optional. |
| `groups.csv` | `group,person_id` | One row per exclusion-group membership. |
| `history.csv` (optional) | `year,giver_id,recipient_id` | Import complete assignments from previous years. |

Keep IDs stable when changing names or emails. Set `active` to `false` instead
of deleting former participants. A person can belong to multiple groups; sharing
any group prevents a match in either direction.

At the top of `santa.swift`, set `drawYear`, replace the `senderEmail` placeholder
with your dedicated Mail address, and customize the email wording if desired.

## Usage

Run these commands from the folder containing your script.

```sh
swift santa.swift                 # Generate a draw and ask whether to save
swift santa.swift --show-matches  # Also display generated or saved assignments
swift santa.swift --send          # Send emails for the saved draw
```

Generation never sends emails. An existing draw for the configured year is reused,
not regenerated. Matches are hidden unless `--show-matches` is supplied.

Sending lists the dedicated sender, recipient addresses, and subjects, then asks
for confirmation. Email bodies are not printed. Allow control of Mail if macOS
requests it. Each successful submission is recorded, so reruns skip those emails.
If sending fails, check Mail before retrying; submission does not confirm delivery.

Keep `history.json`: it stores assignments and email submission progress.
Updates preserve the previous version in `history.json.bak`. Identical CSV history
imports are harmless; conflicting imports are rejected. Importing historical CSV
data can update JSON even if you decline to save a new draw.

## Verification

```sh
swift Tests/run.swift
```

Tests use isolated copies of `Tests/Fixtures` and fake email helpers. They do not
change your participant data or send real emails.

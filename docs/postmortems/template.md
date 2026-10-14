# YYYY-MM-DD: <short title>

Copy to `docs/postmortems/<YYYY-MM-DD>-<slug>.md`, fill in, add a line to
[README.md](README.md). Blameless: describe what the system allowed and what
people knew at the time, never who is at fault. No names; say "the operator".
Times in UTC.

## Summary

Two or three sentences: what broke, for how long, what users saw, the cause.

| | |
| --- | --- |
| Start / end | `YYYY-MM-DD HH:MMZ` / `HH:MMZ` |
| Detected by | alert name, heartbeat, a person noticing |
| Apps affected | `app` labels from [sre.md](../sre.md#service-level) |
| Budget spent | minutes of failed probes per app, and the share of the monthly budget |
| Data lost | none, or what and how much |
| Trigger | which [postmortem trigger](../sre.md#postmortems) applies |

## Impact

What users could and could not do, per app. Numbers from Prometheus or the
smoke suite, not estimates.

## Timeline

| UTC | Event |
| --- | --- |
| HH:MM | first symptom |
| HH:MM | detected |
| HH:MM | mitigated |
| HH:MM | resolved |

## Cause

The chain of events, from the trigger to the user-visible failure. Separate
what is confirmed from what is suspected.

## What went well

## What went badly

## Where we got lucky

## Action items

| Action | Type | Status |
| --- | --- | --- |
| <change> | prevent / detect / mitigate | PR #<n>, roadmap entry, or open |

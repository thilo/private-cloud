@AGENTS.md

# Rules for Claude

Always-apply rules not covered by AGENTS.md. The incidents behind them live in memory.

## Committed text (comments, README, CHANGES.md, commit messages)

- No grading adjectives ("generous", "robust", "matters more here"), no selling.
- Nothing unique to one deployment: no incident dates, measured sizes, asset counts,
  host specs, hostnames, IPs, addresses. Describe the defect and the fix, or the
  mechanism.
- Measurements go in one terse line beside the setting they justify, or into memory.
  Never in the README.
- One place per rationale. Search for an explanation before writing it; if it exists,
  point at it.
- No decision history: no "as discussed", "we considered X", "X was rejected".
- Only actors act. Docs never do anything, and a docs-only change is never phrased as
  system behaviour.

## CHANGES.md

- One line for the change; changed entries mark the delta with "now". Add a reason only
  when the reader can't infer it and no comment beside the setting already carries it.
- No non-changes ("X was already current"); report those in the reply instead.
- A version bump is old version → new version. Don't copy older entries as precedent;
  they predate these rules.

## Commit messages

- Subject: one imperative line, no trailing period.
- Body: one paragraph of three or four lines: what was wrong and why the fix works.
  More mechanism belongs in a comment beside the code.
- No `Co-Authored-By: Claude`/Anthropic trailer unless asked (a local `commit-msg` hook
  strips it too).
- Before committing, scan the whole diff for grading adjectives, dates, measured
  numbers, host facts and duplicated rationale.

## Operating

- Prefer the small fix over a refactor that doesn't remove the constraint behind the bug.
- Never print whole config blobs, env files or `docker inspect` output; assume they hold
  credentials. Immich's `system-config` stores the SMTP password in cleartext; query a
  subtree or strip the path with `#-`.
- Connect to production only when asked for production work. Anything irreversible gets
  a rollback copy first.

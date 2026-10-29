# Handoff body template

Goes after the 3 header lines. Keep the whole file under about 80 lines, and use repo-relative paths.

```markdown

## Goal
What we're trying to accomplish, and what "done" looks like.

## Current Progress
What's done: files changed, commands run, current state (working / partly working / broken).

## Verification State
- Passed: `<command or check>`, and what it proved
- Failed: `<command or check>`, with a short error
- Not run: `<command or check>`, and why

## What Worked
Approaches that succeeded, with enough detail to reuse them (exact commands, config values, the key insight).

## What Didn't Work
Approaches that failed and *why*, so they're not repeated.

## Next Steps
1. Ordered actions. The first is startable immediately: an exact command, or a `path/to/file:line`.

## Key Context (optional)
Decisions and their reasons, constraints, open questions for the user.
```

Verification State records what was actually *run*. Don't list a check as Passed unless it was run in this session, or it was carried over unchanged from a previous update with nothing touched since.

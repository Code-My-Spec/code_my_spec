# Fix Issues Workflow

The `fix_issues` task takes every accepted QA issue and works through
fixes. The unresolved list comes from the DB at session start — there's
no severity filter at this layer (whatever triage promoted to `accepted`
gets fixed; story 608 rule 1).

## Per-issue procedure

For each issue in the prompt:

1. **Understand the problem** — read the issue description and any QA
   result it references.
2. **Fix the code** — use subagents (Agent tool) for the actual fix
   work. Group related issues into one subagent if they share a root
   cause. Each subagent should: read the relevant source, make the fix,
   verify it works.
3. **Resolve** — call `resolve_issue` with the issue `id` and a
   `resolution` summary covering: what was fixed, files changed, how
   the fix was verified.
4. **Run tests** at the end — `mix test` — to verify nothing else broke.

## Scope-aware fixing

Every issue has a `scope` field. Read it before fixing:

- **`app`** — fix application code (controllers, LiveViews, schemas).
- **`qa`** — fix QA infrastructure (seed scripts, auth scripts, the QA
  plan, test tooling). A `qa`-scoped issue means seeds or scripts need
  updating, not application code.
- **`docs`** — fix documentation (specs, README, user stories).

Scope misclassification by triage happens. If you read the issue and
the scope looks wrong, mention it in the `resolution`.

## Regression handling — strict no-silencing rules

If a fix breaks a previously-passing test, that's a regression. Fix
the regression in source code. Never silence it. Specifically:

- **Do not** add `@tag :pending` or `@tag :skip` to a failing test to
  make it stop running.
- **Do not** weaken assertions to make a failing test pass.
- **Do not** delete a failing test rather than diagnose why it broke.

Diagnose the actual cause, fix the offending code, and re-run
`mix test` until green before calling `resolve_issue`.

## QA context — where to look for reproduction details

- **QA plan**: `.code_my_spec/qa/plan.md` — server startup, seeds, auth
  strategy. Read for environment setup before verifying a fix.
- **QA results per story**: `.code_my_spec/qa/<story_id>/` — the failed
  `result_failed_<ts>.md`, screenshots, and the brief. Each accepted
  issue's source QA evidence lives here.

## MCP tools you'll use

- **`get_issue`** — read full issue details by id (when the inline
  description isn't enough).
- **`resolve_issue`** — mark an issue resolved with a resolution
  summary. Required after every fix.
- **`list_issues`** — re-check the accepted list if you need to verify
  you've covered everything (the prompt's initial list is a snapshot;
  the DB is the source of truth).

## Done signal

Every issue with status `:accepted` has been resolved (status moved to
`:resolved` via `resolve_issue`). The evaluator re-queries the DB; if
any accepted issues remain, it returns invalid with the list.

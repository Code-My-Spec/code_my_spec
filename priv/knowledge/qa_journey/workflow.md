# QA Journey Workflow

The `qa_journey` task is a three-phase pipeline that takes an app from
"no end-to-end coverage" to "passing journeys codified as LiveView
tests."

| Phase | Artifact | Requirement node |
|---|---|---|
| 1. Plan | `.code_my_spec/qa/journey_plan.md` | `qa_journey_plan` |
| 2. Execute | `.code_my_spec/qa/journey_result.md` | `qa_journey_execute` |
| 3. Codify | `test/journeys/*_test.exs` | none — same session as Phase 2 |

The same module satisfies both nodes. Each is gated by a `:path_exists`
check on the previous phase's artifact, so the agent walks forward one
phase per session. The command prompt always announces all
three phases — phases whose artifacts already exist are marked **SKIP**;
the agent works on the first un-skipped phase.

## Inputs the agent should always read first

- `.code_my_spec/qa/plan.md` (if present) — app overview, tools registry,
  auth strategy, seed strategy. Produced upstream by `qa_setup`.
- `show_namespace_hierarchy` — the system's components as a namespace tree.
  Helps scope which surfaces to journey.
- Stories summary (written by `command/2` to
  `.code_my_spec/qa/stories_summary.md`) — full descriptions and
  acceptance criteria. The prompt shows only titles; details live here.

If there is no QA plan, read the app's `router.ex` and
`config/*.exs` directly to understand routes, auth, and features.

## Phase 1: Journey Planning

**Artifact:** `.code_my_spec/qa/journey_plan.md` matching the
`qa_journey_plan` document spec (included in the prompt).

Journeys are **end-to-end user paths**, not story-by-story checklists.
Each journey traces setup → authentication → core workflow →
verification.

### Procedure

1. Read the context files listed above.
2. Identify 3–5 user roles or "first-day experiences" worth tracing
   (e.g. new-user signup → first action; returning admin → bulk import;
   API consumer → first request).
3. For each journey:
   - **Name** — short, descriptive (`new_user_first_post`).
   - **Role** — which user persona.
   - **Numbered steps** — concrete actions, not abstractions.
     ("Click 'Sign up'", not "register a user").
   - **Expected outcome** — what the user observes when it works.
4. Add a **Prerequisites** section covering:
   - Server startup command and port.
   - Seed scripts to run (cite paths from the QA plan).
   - Test credentials and how they're provisioned.
5. Write the plan to `.code_my_spec/qa/journey_plan.md`.

### Anti-patterns

- One-journey-per-story. Journeys cut across stories; pick paths a real
  user would walk, not test cases.
- Abstract steps. "User completes onboarding" is not a step — list the
  clicks and form fills.
- Inventing acceptance criteria the stories don't have. If a story
  needs new criteria, the gap belongs upstream, not in this plan.

## Phase 2: Journey Execution

**Artifact:** `.code_my_spec/qa/journey_result.md` matching the
`qa_journey_result` document spec (included in the prompt).

### Server prerequisites

1. Check whether the Phoenix server is already listening
   (`lsof -i -P -n | grep LISTEN`).
2. If not, start it from the project's cwd (`mix phx.server &`).
3. Verify via MCP browser tools — load the app URL and confirm a 200
   response before journeying.

### Tool rules — pick by Phoenix pipeline

- **UI / LiveView (`:browser` pipeline):** MCP browser tools only.
  Navigate, click, type, screenshot. Authenticate via the login form.
- **API endpoints (`:api` pipeline):** `curl` with API key headers.
  Use `.code_my_spec/qa/scripts/authenticated_curl.sh` when the plan
  registers it. Never use curl with session cookies for browser routes.

### Procedure

1. Read `.code_my_spec/qa/journey_plan.md` for the journeys and
   prerequisites.
2. Run seed scripts from the prerequisites section.
3. For each journey:
   - Walk every numbered step in the browser.
   - Capture a screenshot at each key state (initial, mid-flow,
     success/error). Save to `.code_my_spec/qa/journeys/screenshots/`.
   - Record observations: passed/failed, deviations, anything that felt
     off (even if functionally correct).
4. If you find a gap in the plan, fix the plan in-flight — don't work
   around it.
5. Write the result to `.code_my_spec/qa/journey_result.md`.

### Anti-patterns

- Skipping screenshots — they're evidence, not decoration.
- Marking a journey "pass" when a step deviated from the plan. If the
  app diverged, record it and decide pass/fail based on the outcome.
- Treating the journey list as exhaustive — if you spot something
  obvious that the plan missed, exercise it and add a journey for
  next run.

## Phase 3: LiveView Tests

**Artifact:** `test/journeys/{journey_name}_test.exs` — one test per
**passing** journey from Phase 2. Written in the same session as Phase 2;
no requirement gates it.

### Procedure

1. For each journey marked `pass` in the result, write a
   `Phoenix.LiveViewTest` test at `test/journeys/{journey_name}_test.exs`
   using the project's `ConnCase`. No browser driver.
2. Translate steps into `live/2`, `form/3` + `render_submit/1`,
   `element/3` + `render_click/1`, `follow_redirect/2`, and assert on
   `render/1` / `has_element?/3`.
3. Pull seed setup and auth from the prerequisites section
   (`log_in_user/2` or the project's equivalent).
4. Make each test independent — standalone, any order.
5. Run the file once and confirm it passes before stopping.

### When journey tests already exist

If `test/journeys/*_test.exs` files exist (the prompt lists them),
extend them rather than duplicating.

### Anti-patterns

- Writing tests for failed journeys. Codify what passes; the
  failure is a bug to fix upstream.
- Hardcoded credentials. Pull from prerequisites or fixtures.
- Skipping the local test run. A test that's never been green is no
  better than no test.

# QA Story Workflow

The `qa_story` agent task is a per-story QA cycle: write a brief, then execute
it against the running app. The project-wide QA plan
(`.code_my_spec/qa/plan.md`) is a prerequisite — produced upstream by
`qa_setup`, not written here.

QA completion is recorded by a DB-backed attempt via `submit_qa_result`. There
is no result.md file in the loop. Findings are filed via `create_issue` as
they're uncovered and linked into the attempt by id.

## Phase 1: Testing brief

**Artifact:** `.code_my_spec/qa/<story_number>/brief.md`

The brief is the concrete plan for testing this story — which tools to use,
how to authenticate, what scenarios to test, and what to assert.

Procedure:

1. Read `.code_my_spec/qa/plan.md` for App Overview, Tools Registry,
   auth strategy, and Seed Strategy.
2. Run seed scripts to verify setup works for this story.
3. If this story needs additional seeds or plan updates, make them now
   and update plan.md (don't fork into a story-specific plan).
4. Read the BDD spec files listed in the prompt. They have selectors,
   test data, and assertions.
5. If a linked component is listed in the prompt, read its source and
   spec to understand the feature.
6. Write the brief to `.code_my_spec/qa/<story_number>/brief.md` matching
   the `qa_story_brief` document spec from the prompt.

## Phase 2: Execute tests

There is no `result.md` artifact in this phase. Findings flow through
`create_issue` as you discover them; the run ends with one call to
`submit_qa_result`.

### Tool rules — pick by Phoenix pipeline, not by guess

- **UI / LiveView (`:browser` pipeline):** MCP browser tools only.
  Navigate, click, type, screenshot. Log in via the browser (credentials
  and login steps are in the plan).
- **API endpoints (`:api` pipeline):** `curl` with API key headers.
  ALWAYS single-line commands. Use
  `.code_my_spec/qa/scripts/authenticated_curl.sh` for API-key auth.
- **NEVER** use curl with session cookies or CSRF tokens for
  browser-authenticated routes. If a route is behind
  `:require_authenticated_user`, test it with MCP browser tools.

### Testing approach

- Capture a screenshot at each key state (initial load, after
  interactions, success/error states). Save to
  `.code_my_spec/qa/<story_number>/screenshots/`. Screenshots are evidence
  and remain valuable — attach the path in the issue description for
  any finding that ships a screenshot.
- After scripted scenarios, explore freely: unexpected inputs, edge
  cases, empty states, anything that feels off.
- Reference existing scripts in `.code_my_spec/qa/scripts/` by path
  rather than inlining shell commands.

### Filing findings

The moment you observe something wrong — a broken UI, a 500, a missing
feature, an unexpected behavior — call `create_issue` and hold the
returned id. Don't accumulate findings in a notepad. Don't write them
into a markdown file. The DB issue is the canonical record.

- `title` — short, scannable.
- `severity` — critical / high / medium / low / info.
- `scope` — `app` for app-under-development bugs; `qa` for QA infrastructure
  problems; `docs` for docs gaps; (`framework` is a server-side concept and
  not selectable from the local list_issues filter, but `create_issue`
  itself supports it for harness issues).
- `story_number` — the story this finding relates to, when relevant.
- `description` — the reproduction, the expected vs actual, file paths,
  and any screenshot or evidence path.

If a finding is a duplicate of an existing issue (you'll see them in the
prompt's "Existing Issues" section), don't refile.

### Procedure

1. Read the brief at `.code_my_spec/qa/<story_number>/brief.md` for the
   complete plan.
2. Read `.code_my_spec/qa/plan.md` for auth strategy and seed commands.
3. Read `priv/knowledge/qa-tooling.md` and `priv/knowledge/qa-tooling/`
   for tool usage patterns.
4. Run seed scripts to set up test data.
5. If a linked component is listed in the prompt, read its source to
   understand implementation details.
6. Execute each test scenario from the brief.
7. Capture screenshots at key states (save to the screenshots directory).
8. For every finding, call `create_issue` immediately and remember the id.
9. If you find a gap in the plan or the brief, fix it in-flight — update
   `plan.md` or `brief.md` rather than working around the gap.
10. Call `submit_qa_result` once at the end with `status`, the structured
    `scenarios` list, and the full `issue_ids` list. Then stop the session.

## What the evaluator does when you stop

The evaluator runs a thin check chain:

1. Validates that `.code_my_spec/qa/plan.md` exists with required sections.
   (If missing, returns invalid pointing at `qa_setup`.)
2. Validates that `.code_my_spec/qa/<story_number>/brief.md` exists and parses.
3. Checks whether a DB-backed pass attempt exists via
   `CodeMySpec.Qa.qa_complete?/2`. If yes, the requirement is satisfied
   and the session ends.
4. If no DB attempt exists but the brief is valid, feedback is returned
   demanding a `submit_qa_result` call. The requirement does NOT satisfy
   off a brief alone.

## The submit_qa_result contract

```
submit_qa_result(
  task_id: <task_id from start_task>,
  status: "pass" | "partial" | "fail",
  scenarios: [
    %{name: "...", status: "pass|partial|fail", observation: "..."},
    ...
  ],
  issue_ids: [<every id returned from create_issue this run>]
)
```

Rules:

- `status: "pass"` with `issue_ids: []` is allowed — clean pass, nothing to
  file.
- `status: "partial"` or `"fail"` with `issue_ids: []` is **rejected** by
  the tool. File the findings first.
- Only `status: "pass"` satisfies the `qa_complete` requirement. Other
  statuses record an audit row but leave the requirement open.
- Resubmitting on the same `task_id` is allowed — each call creates a new
  attempt; the latest is canonical.
- Every scenario entry requires an `observation`, whatever its own
  `status` — a scenario submitted without one is rejected.
- When zero measurements are obtainable for a scenario (a command hangs,
  tooling is down, nothing comes back), there is no `blocked` or
  `inconclusive` verdict to reach for — `status` is one of `pass` /
  `partial` / `fail` and nothing else. Submit `status: "partial"`, with
  one scenario per probe attempted whose `observation` records what was
  run and what came back (e.g. "ran mix spex on criterion_1261; command
  timed out at 60000ms, no stdout, stderr or scenario results returned"),
  and the blocker's issue id in `issue_ids`. The inability to measure
  *is* the observation — what is missing is the measurement, not the
  observation. Do not submit `fail`: that asserts the behavior is
  broken, which was never observed, and leaves a false failing record
  someone later has to disprove.

## The submit_issue_qa_result contract

Story 1091's issue-side counterpart: one QA pass on a single issue rather
than a whole story.

```
submit_issue_qa_result(
  issue_id: <issue being tested>,
  task_id: <your active qa_complete task id on this issue>,
  status: "pass" | "partial" | "fail",
  scenarios: [
    %{name: "...", status: "pass|partial|fail", observation: "..."},
    ...
  ],
  issue_ids: [<ids filed via create_issue this pass>]
)
```

Same discipline as `submit_qa_result`: `partial` or `fail` must carry at
least one id in `issue_ids`, rejected otherwise; every scenario entry
needs an `observation` regardless of status; the unmeasurable-case policy
above applies here too. `status: "pass"` resolves the issue and frees the
team bound to it. Any other status leaves the issue open and bound, and
the coder is offered it again — including a `partial` that only means
"could not be measured", which still bounces back to a coder with nothing
to act on. Worth revisiting if this keeps happening; not a reason to
submit something other than `partial` in the meantime.

# QA Story Workflow

The `qa_story` agent task is a two-phase QA cycle for a single user story:
write a brief, then execute the brief. The project-wide QA plan
(`.code_my_spec/qa/plan.md`) is a prerequisite — produced upstream by
`qa_setup`, not written here.

If `result_complete.md` already exists for this story, the evaluator
short-circuits — QA already passed.

## Phase 1: Testing brief

**Artifact:** `.code_my_spec/qa/<story_id>/brief.md`

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
6. Write the brief to `.code_my_spec/qa/<story_id>/brief.md` matching
   the `qa_story_brief` document spec from the prompt.

## Phase 2: Execute tests

**Artifact:** `.code_my_spec/qa/<story_id>/result.md` → renamed by the
evaluator on pass to `result_complete.md`, or on fail to
`result_failed_<timestamp>.md`.

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
  `.code_my_spec/qa/<story_id>/screenshots/`. Screenshots are evidence
  and must be committed.
- After scripted scenarios, explore freely: unexpected inputs, edge
  cases, empty states, anything that feels off.
- Reference existing scripts in `.code_my_spec/qa/scripts/` by path
  rather than inlining shell commands.

### Procedure

1. Read the brief at `.code_my_spec/qa/<story_id>/brief.md` for the
   complete plan.
2. Read `.code_my_spec/qa/plan.md` for auth strategy and seed commands.
3. Read `priv/knowledge/qa-tooling.md` and `priv/knowledge/qa-tooling/`
   for tool usage patterns.
4. Run seed scripts to set up test data.
5. If a linked component is listed in the prompt, read its source to
   understand implementation details.
6. Execute each test scenario from the brief.
7. Capture screenshots at key states (save to the screenshots directory).
8. If you find a gap in the plan or the brief, fix it in-flight — update
   `plan.md` or `brief.md` rather than working around the gap.
9. Write the result to `.code_my_spec/qa/<story_id>/result.md` matching
   the `qa_result` document spec from the prompt.
10. Stop the session. The evaluator takes over from here.

## What the evaluator does when you stop

The evaluator runs a single check chain:

1. Validates that `.code_my_spec/qa/plan.md` exists with required sections.
   (If missing, returns invalid pointing at `qa_setup`.)
2. Validates that `.code_my_spec/qa/<story_id>/brief.md` exists and parses.
3. Validates that `.code_my_spec/qa/<story_id>/result.md` exists and parses
   against the `qa_result` spec.
4. Files every issue from the result document to the DB via
   `Issues.create_from_qa_result/3`. Issues are filed regardless of
   pass/fail.
5. Promotes or archives the result based on `status`:
   - `status: pass` / `passed` → `result.md` renamed to
     `result_complete.md`. Done signal for the requirement.
   - `status: fail` / `partial` → `result.md` archived as
     `result_failed_<timestamp>.md`. Requirement stays unsatisfied. The
     next run sees no `result.md` and starts Phase 2 fresh.

The evaluator always returns `:valid` once `result.md` is validated —
session ends. The requirement system separately checks for
`result_complete.md`, so the story stays open until QA actually passes.

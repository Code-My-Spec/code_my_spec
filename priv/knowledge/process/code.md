# The code process

What order component work happens in, and what finishes each step.

Each task's prompt carries what it needs. What no prompt carries is the
shape they form together — so an agent handed one task can do it correctly
and still have no idea what it is in the middle of. That is what this is for.

## Two different chains

Do not confuse them. They run at different grains and meet in one place.

- **The story chain** — one story from shaped to shipped. In
  `process/product.md`.
- **The component chain** — one component from designed to built. Below.

They meet at `component_linked`: a story names the component it is about,
and that is the first requirement on the story chain. Component work and
story work then proceed largely independently.

## The design is records, not files

A component, its type, its description, its parent and what it depends on
are records, authored through the tools — `create_component`,
`update_component`, `add_dependency`, `remove_dependency` — or by executing
an architecture proposal. No spec file describes a component, and editing
one changes nothing. Code that appears with no component behind it is
picked up by the sync as *discovered*; the design is what was *authored*.

## The component chain

One step per component:

| Step | Requirement | Finished by |
|---|---|---|
| Code written | `implementation_file` | the file exists |

The order is in the prerequisites. A **context** builds its children first,
then itself. A **live context** is a container: only its children are
built. **Infrastructure** has no requirements at all — it is deliberately
not something this process builds.

So do not reason from "the component graph". Reason from the requirements
you were actually handed.

## Where the tests are

Behaviour is held by the story, not the component. A story's acceptance
criteria become BDD specs (`bdd_specs_exist`), and the story is not done
until they pass (`bdd_specs_passing`). Write the spex first, then the code
that makes them pass: written backwards, a test describes whatever got
built and can never disagree with it.

## What "finished" means mechanically

Every requirement is satisfied by a check, not by an assertion that you
did it. The checks are mostly:

- **the file exists** at the path the requirement names;
- **the file is valid** — it parses and carries the sections required of
  its kind;
- **the tests pass**;
- or a **delegated** check that asks a context a question (this is how
  `qa_complete` reads a QA attempt, for instance).

Two consequences:

- **You cannot talk a requirement into being satisfied.** If the check
  says no, something is genuinely absent or genuinely red.
- **A requirement can go back to unsatisfied.** These are computed, not
  latched. Delete the file and the requirement reopens.

## Automatic and manual evaluation

Most requirements are **automatic**: the stop hook evaluates your work when
you stop, and you do not call anything. A few are **manual** and need an
explicit `evaluate_task` call — the task prompt tells you which you are in.

Calling `evaluate_task` on an automatic task is harmless. *Not* calling it
on a manual one leaves the task open with the work sitting there finished,
which looks from outside exactly like an agent that stalled.

## When an analysis run is stuck

Normal analysis finishes asynchronously — you get a "Your X run finished"
message when it lands, and you do not poll for it. `start_analysis` also
takes `paths` to scope a run to specific files, for a targeted recheck
rather than the full sweep.

You do not carry a tool to inspect or cancel an admitted run —
`check_machinery` and the harness's own run inventory belong to main under
`process/main_agent.md`. That is deliberate: a fault in the analysis
machinery is a single shared thing underneath every agent, and letting
every role poll for it separately multiplies the confusion rather than
fixing it.

So when a run is genuinely stuck — not merely slow — report it to main with
`ask_user_question`, naming the working copy, the commit, and what you were
trying to validate, and wait. Main inspects and recovers the machinery; you
resume by calling `start_task`/`evaluate_task` again once it tells you to,
not by guessing at a tool name that does not exist.

`await_analysis` is retired. If your tool list still shows it — fetched at
session start, before it was removed — calling it explains this and names
the two HTTP endpoints (`/analysis/run`, `/analysis/wait`, documented in
AGENTS.md) that replaced it; reconnecting through `/mcp` refreshes the list.

## When specs are red

`bdd_specs_passing` has its own task, and its instruction is worth
repeating because it is easy to invert under pressure: **fix the
implementation, not the spec.** The spec is the agreed behaviour. Change a
spec only when it has a genuine bug — a wrong assertion, a broken setup —
and not because it is what stands between you and green.

A red spex in your working copy is yours to fix whether or not you wrote
it.

## Next

When the specs are green, the code still is not anywhere useful — it is in
your worktree, and the running application cannot see it. Continue with
`process/devops.md`.

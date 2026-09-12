# The code process

What order component work happens in, and what finishes each step.

None of the six task modules in this family has a playbook, because each
one's prompt carries what it needs. What no prompt carries is the shape
they form together — so an agent handed one task can do it correctly and
still have no idea what it is in the middle of. That is what this is for.

## Two different chains

Do not confuse them. They run at different grains and meet in one place.

- **The story chain** — one story from shaped to shipped. In
  `process/product.md`.
- **The component chain** — one component from specified to green. Below.

They meet at `component_linked`: a story names the component it is about,
and that is the first requirement on the story chain. Component work and
story work then proceed largely independently.

## The component chain

The order, which is the thing worth memorising:

```
spec → valid → [children's specs] → review → valid
     → [children's impl] → impl → test → passing
```

Read as prose: **specify the parent, specify its children, review the
design as a whole, then build the children, then build the parent, then
make the tests pass.**

Step by step, with what satisfies each:

| Step | Requirement | Finished by |
|---|---|---|
| Parent spec written | `spec_file` | the spec file exists |
| Parent spec is sound | `spec_valid` | the file parses and has its required sections |
| Each child specified | `spec_file` (per child) | same, once per child |
| Design reviewed | `review_file` | the review file exists |
| Review is sound | `review_valid` | it parses |
| Tests written | `test_file` | the test file exists |
| Tests match the spec | `test_spec_alignment` | the tests assert what the spec says |
| Code written | `implementation_file` | the file exists |
| It works | `tests_passing` | the test run is green |

### Why specs come before tests and tests before code

The spec is the argument for what this thing should do. The test is that
argument made executable. The code is what makes the test pass.

Written in that order, each step has something to check itself against.
Written backwards, the spec becomes a description of whatever got built,
which is a document that can never disagree with the code and therefore
cannot catch anything.

### Why the review sits in the middle

The design review runs after every spec exists and before any code does.
It is the last point where changing the shape is cheap. A review that runs
after implementation is a code review — useful, different, and too late to
move a boundary.

## The graph is per component type

There is not one component graph. `context`, `live_context`, `controller`,
`schema`, `behaviour`, `json` and `liveview` each have their own, and
`infrastructure` has **no requirements at all** — an infrastructure
component is deliberately not something this process builds.

So do not reason from "the component graph". Reason from the requirements
you were actually handed.

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

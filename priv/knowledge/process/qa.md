# The QA process

How a story gets tested, and — the part the per-task playbooks do not
cover — how the result is *recorded* and what makes it count.

The playbooks describe testing: `qa_setup/`, `qa_story/`, `qa_journey/`,
`qa_integration_plan/`. Read the one for your task. This document is the
bookkeeping around them, which is unwritten everywhere else and is where
the surprises are.

## Reaching main or product

`message_agent` only works between teammates sharing a working copy — you
and the coding agent on your own checkout, say. It is not how you reach
main, product, or anyone on another copy: that role does not carry the
tool at all, and a different spelling will not change that. Use
`ask_question` instead — whichever of main or product is running
receives it, not the user, unless neither is.

## QA is a browser, not a spex run

Spex prove the surface behaves. QA is a person-shaped agent using the
application and reporting what it saw. A story whose specs are green can
still fail QA, and that is the point of having both.

## Before QA can run at all

`qa_complete` has one prerequisite: **`story_promoted`**. The
story's code has to be on the checkout the app runs from, or QA is testing
a stale application and reporting on code nobody wrote. See
`process/devops.md`.

That prerequisite was added after nine stories reached QA on one day whose
code had never left the coding agent's worktree.

Part of the same gate is the preview's status, and the rule is narrower
than "the app must be healthy":

| Status | QA can run? |
|---|---|
| `serving` | yes |
| `erroring` | **yes** |
| `down` | no |
| never reported (`nil`) | yes |

`erroring` passing is deliberate. **A 500 is the application answering** —
that is a QA finding, not a reason to keep QA away from it. `down` refuses
because there is nothing to test; the fix is to promote, which starts an app that is down.
`nil` passes because holding every story on a status nobody has reported
yet would be a gate no agent can clear.

## An attempt is the unit

Every submission inserts a **new, immutable row**. Nothing is ever edited.
An attempt carries a status (`pass`, `partial`, or `fail`), at least one
scenario (each with a name, a status and an observation), the ids of any
issues filed, and a link to the attempt it superseded.

Resubmitting on the same task is allowed and expected — each call makes
another attempt.

## What makes an attempt count

Exactly one attempt decides the requirement:

> **`qa_complete` is satisfied iff the MOST RECENT attempt on the story is
> `pass` and carries no invalidation.**

Two consequences that catch people, both following from "most recent"
rather than "any":

- **A later attempt overrides an earlier one, downward as well as
  upward.** A `pass` followed by a `fail` leaves the requirement
  unsatisfied. The newest attempt is the answer, whatever it says.
- **It is not a count.** Ten passes and then one `partial` is not
  satisfied. One `pass` is.

You may see a docstring or two claiming "at least one valid pass attempt
exists". That wording is wrong and the code is latest-attempt-only; do not
build on the docstring.

Only `pass` satisfies. `partial` and `fail` record an audit row and leave
the requirement open — which is the useful behaviour, because the audit
row is what a later reader uses to see what was tried.

## Invalidation

An invalidation says a recorded pass should not have counted. It attaches
to one attempt, carries a mandatory non-blank reason, and there can be at
most one per attempt. The original row is preserved — invalidating does
not delete evidence, it annotates it.

**A pass that was later invalidated is not one, and re-QA is required.**

Two things about invalidation that matter more than the mechanism:

- **It is manual, always.** An engineer calls the tool or clicks it in the
  story view. There is no automatic invalidation — in particular, an
  attempt is **not** invalidated when the code under test changes. No
  attempt carries a commit or a fingerprint, so nothing could notice.
- **What re-clamps QA automatically is the prerequisite, not the row.**
  When the running copy drifts, `story_promoted` goes unsatisfied and
  QA stops being offered. The attempt row is untouched and still says
  `pass`. So a story can hold a genuine pass and still not be done.

## Submitting

`submit_qa_result` takes the `task_id` from `start_task`, a `status`, a
list of `scenarios`, and `issue_ids`.

- **A non-pass with no `issue_ids` is rejected.** File the findings first.
  A failure with nothing attached is dead work: nobody can act on it and
  nothing reads a prose blob.
- There is deliberately **no free-text findings field.** Findings are
  issues, and issues are rows somebody can be assigned.
- Screenshots go on disk under the story's QA directory. They never go
  through the tool.

### Evidence is checked, and does not block

On a pass, the tool checks whether the story's QA evidence is committed.
If it is not, you get told — but the attempt still lands and
`qa_complete` is satisfied either way. **The gate there is the reader's
attention, not the database.** Commit the evidence; nothing will stop you
if you don't, and the next person to look will find nothing.

If this copy cannot commit at all — a read-only checkout — there is no
workaround that pretends otherwise. Hand the reviewed artifact to a
writable owner through a completion handoff; see `process/main_agent.md`.

## Re-testing

Never resubmit without re-testing. A resubmission is a claim that you ran
it again, and since the latest attempt is the canonical one, a resubmitted
stale pass overwrites a real failure with a fiction.

## A harness-served change has a live route too

`run_script` and `tool_docs` are served by the harness on *main's*
checkout, not this copy's. A change whose deliverable is served by the
harness itself -- a new MCP tool, a `tool_docs` entry, a knowledge doc, a
prompt -- exists only on this copy until it is promoted, so calling it
through your own `run_script`/`tool_docs` before promotion answers with
main's catalog, which correctly does not have it yet. That is not evidence
the change does not work; it is evidence you asked the wrong process.

Do not defer the live check to after promotion. Verify it against this
copy's own running app instead:

1. `ensure_app_running` (through `run_script`) to get this copy's own app
   URL. It is a real, separate instance compiled from this copy's own
   code, including the change under test, on its own port and its own
   database -- a clone of main's dev database made when the copy was
   created, so the project's deploy key on it is real and usable.
2. `get_local_app_token({url = <that url>})` to mint a short-lived access
   token against that same instance. It trades the project's deploy key for
   the token server-side -- the same exchange `CmsHarness.Token` does for
   the harness itself, at `POST /api/sprite/token` -- and hands back only
   the resulting token. The deploy key itself is never returned to you and
   must never appear in anything you write down (evidence, issues,
   `update_issue`, anywhere): it is a long-lived secret, not the thing
   this flow is for.
3. `call_mcp_server({url = <that url>, path = "/mcp/harness", tool = "...",
   arguments = {...}, headers = {["Authorization"] = "Bearer " .. token}})`
   to call the new tool for real, through its actual MCP-facing surface.
   No `X-Harness-Id` is needed here -- unlike the shared server, this
   instance's database holds only this one copy's data.

A knowledge doc or a prompt has no tool to call this way; read it back
through this same instance's own `read_knowledge`/equivalent if one exists,
or note in the attempt that it was reviewed as a document rather than
exercised live, and say why.

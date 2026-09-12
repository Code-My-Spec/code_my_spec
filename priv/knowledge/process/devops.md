# The devops process

Getting finished work onto the checkout the application actually runs from,
and knowing whether it got there.

There is no playbook for `promote_work`. This is it. The task looked small
enough not to need one, and the hour it cost is the reason this document
exists — see "Three ways a success reads as a failure" below, which is the
whole point and worth reading before your first promotion rather than
after.

## The thing to understand first

**The dev server on `:4000` always runs from the main checkout.** It never
runs from a worktree.

So edits you make in a worktree are invisible to the running application —
not stale, not cached, *absent*. A fix that is committed, pushed and green
can be missing from every response an agent sees, and nothing about that
looks like a mistake. Promotion is what closes that gap, and until you
promote, testing the running app tells you nothing about your work.

## The two tools

Both take no arguments and run the same thing.

- **`promote`** — returns immediately; the outcome arrives later as an
  agent message. Needs an agent to message, so it refuses if there isn't
  one.
- **`promote_sync`** — blocks and answers. The external door: a caller
  reaching in over MCP has nowhere to be messaged, so this one waits.

The merge target is never chosen by the caller. The running dev copy sits
on main, so a promotion has exactly one target.

## What actually happens

1. **Preflight.** Refuses on a harness environment — it cannot reach the
   disk. Requires a designated main working copy that has reported a root.
2. **Uncommitted work.** `git status --porcelain` on the copy you are
   promoting *from*. Anything at all → `this copy has uncommitted work.
   Commit it, then promote.` This is checked before everything else.
3. **The gate.** Recorded problems answer immediately; only a clean result
   waits for the sweep. Any enforceable `:error` problem →
   `this copy is carrying N problem(s), so it promotes nothing`, listing
   the first ten.
4. **A fresh analyzer sweep.** Stale or never-run sources get dispatched
   and waited on. Stale analyzers are swept, not refused.
5. **Merge** into the running checkout. A conflict is left in place —
   never auto-aborted — so you can resolve it.
6. **A second sweep**, of the running copy this time. The bar is *"the
   merge added no new problems"*, not *"the target is clean"*: problems
   the running copy already carried are subtracted before comparing.
7. **Restart**, unconditionally.

Promoting **from** the running copy is a restart only — no gate, no sweep,
because a restart carries no code.

### The sweep and its timeout

Four analyzers: **compiler, credo, exunit, spex**.

`sweep_timeout` defaults to **2 minutes**. Real sweeps on this project
routinely take **two to five**. That is not a bug and it is not tuned up,
because the wait happens inside a tool call and a tool call that blocks for
ten minutes is worse than one that tells you to come back.

The practical consequence: **a timeout here is the common case, not the
alarming one.**

### The restart

Requires a `justfile` at the running root; without one the merge still
landed and the app is still serving what it was. Otherwise it runs
`just restart`, which kills whatever holds `:4000`, runs `mix ecto.migrate`
unconditionally, starts a detached `mix phx.server`, polls for 20 seconds,
and then refreshes the harness — because moving one without the other *is*
the version skew.

The restart is never conditional on "did this merge need one". Whatever
would decide that is a second implementation of the code-reloading rules,
and it would be wrong on exactly the changes that matter.

## Three ways a success reads as a failure

This is the part that cost the hour. All three of these are promotions
that **worked**, reporting in a way that reads like they did not.

1. **`the gate is waiting on a fresh analyzer sweep… Nothing was
   merged.`** — Accurate. Nothing was merged *yet*; the sweep is still
   running and will finish. Promote again shortly and it answers against
   fresh results. Retrying is the correct move, not a workaround.

2. **`the merge landed, but the sweep verifying it did not finish in
   time.`** — The merge **has landed**. The running copy has your work.
   What is unknown is only whether the merge added problems. This answered
   four times in a row on one occasion while the merge had in fact landed
   every time.

3. **A restart reported as a timeout.** The channel that would confirm the
   restart **dies in the restart it is confirming**. So the confirmation
   never arrives and the call reports a timeout, on a restart that
   happened. Separately, `just restart`'s own 20-second poll prints
   `still starting after 20s — it is detached and may yet come up` and
   exits successfully, because the server is detached and "not answering
   yet" is routine.

The shared shape: **the absence of a confirmation is being reported, and it
reads as the absence of the thing.** In every one of these cases the right
next move is to go and look, not to retry harder and not to start
debugging the gate.

## How to actually check, in one line

Do not infer it from the promotion's answer. Read what the server says it
is serving:

```
[Boot] serving <short-sha>
```

Emitted at boot, in `~/.codemyspec/web.log` (logfmt, `src=web`, with an
`inst=<os pid>` that changes on every restart) and in
`~/.codemyspec/phx_4000.restart.log` (raw stdout, rotated each restart).
`just restart` also prints `✓ 4000 is answering on <short sha>` inline.

**A new `inst=` is the proof the restart happened.** A matching sha is the
proof your work is what is being served.

Look in `web.log`, **not** `server.log` — `server.log` is the packaged
`cms server` on `:4003` and knows nothing about `:4000`. Asking it returns
silence, and silence is indistinguishable from a failure. The full log map
is in the project's `CLAUDE.md`.

## If you take one thing

A promotion that says something inconclusive has usually succeeded. Check
`[Boot] serving <sha>` before you believe otherwise — it is one grep, and
it answers the question that four retries do not.

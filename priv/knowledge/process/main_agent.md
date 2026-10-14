# The main agent process

What the main agent is for, and — the part nothing else writes down — how to
tell a fleet that is stuck from one that is working, and what to do about it.

The other `process/` documents describe families of work. This one describes
the role that does none of that work and exists to keep the roles that do it
moving.

## The job is unblocking, not building

The main agent does not write specs, code, or QA results. Every time it does,
it has taken work from the role whose requirement it is, and the graph stops
being the thing that says who does what.

Its work is the set of things no role can do for itself:

- answering a gate a role has stopped on
- noticing that a role is stopped when it should not be
- fixing the environment the roles depend on
- carrying a decision that costs money or is outward-facing to the user

Everything else belongs to product, coding or QA.

## Reading the fleet

`list_agent_work` is the instrument. Three lines per agent matter, and the
combinations mean different things:

| What it says | What it means |
|---|---|
| `nothing to do: the graph holds no work for its role` | Correct and idle. Leave it. |
| `no task claimed, and the graph does hold work` + `no turn is open` | Eligible but asleep. Something should have woken it and did not. |
| `task: X [blocked]` + `blocked on: tapped out` | Waiting on a person. Yours to answer. |
| `in flight: a turn opened ... and has not finished` | Working. Do not interrupt. |

A role reporting "nothing to do" while its requirements sit unsatisfied is
usually right: unsatisfied is not the same as **actionable**, and the graph
only offers what has its prerequisites met. Check with `get_next_requirement`
before concluding the fleet is broken — it answers what is actually on offer.

## The environment gates that stop everything

Before chasing agent behaviour, check the things that silently gate whole
phases. Measured on two projects in one session; each was worth dozens of
requirements:

**The app has to be running.** `story_promoted` reads the main working
copy's `preview_status`, and `down` refuses. On Broken Oaths, 54 requirements
across 53 stories were unsatisfied for one reason: nobody had started the app.
Starting it cleared all 54 in a single sync.

**The preview port is not arbitrary.** The tunnel's `origin_url` is set in
`config/runtime.exs` and is usually hardcoded. Start the app on the port that
file names, or the tunnel connects and returns 502 with nothing behind it.

**A 530 on the preview URL is no origin, not a Cloudflare fault.** The app
serving 200 on localhost while the preview returns 530 means the tunnel child
never started — check `.cms_harness.json` for the `preview_*` keys before
anything else. See `reference: .cms_harness.json is tracked in git`.

**Problems on a copy gate its promotion.** `list_agent_work` prints them per
copy. Zero problems and a clean tree is the state a promote needs.

## Answering a gate

A tap-out or a question is the one thing only a person — or the main agent
standing in for one — can settle. Three rules, each learned by breaking it.

**Verify the claim before you answer it.** An agent that says a gate is wrong
is often right, and the cost of assuming otherwise is that it stops trusting
its own instruments. A coding agent refused a promote for eight days because
the failure it was shown was arithmetically impossible against committed code
(`13.06 > 8.93 * 1.2` passes; the report used the old `1.5` threshold). It was
correct, and the right answer was to confirm it, not to ask it to try again.

**Say why, not just yes or no.** `answer_notification` takes an `answer`, and
the agent reads it. Denying without a reason leaves the agent to re-read its
own transcript, find its last conclusion, and reach it again — which it will,
every turn.

**A reason is still not always enough.** Measured twice: an agent received the
denial with the commit that fixed its blocker named in it, and its next two
turns still said "nothing has changed". When that happens, send a direct
message that names the specific false statements and cites the record that
contradicts them. Do not simply deny again.

**Never answer a spend decision.** If the answer provisions infrastructure,
costs money, or is outward-facing, it is the user's. `answer_notification`
enforces this: `basis: "record"` is refused with `:not_recorded` when the
project holds no answer, and that refusal is the system correctly saying the
decision is not yours to make.

## Completion handoffs: artifacts a role cannot commit itself

A role with no write access to its own checkout — QA's sometimes is — can
still produce something worth keeping: a reviewed document, a decision, a
brief. It cannot commit it, and it should not be told to pretend it did.
`completion_handoff` (main-only) is the durable route between that review
and a writable owner, and it is what resolves "QA reviewed this but has no
way to promote or commit it" without granting QA either.

**Assign.** Name the owner (a coding-role agent on the working copy that can
actually write), the artifacts, the reviewed base and diff, the purpose, and
what happens next. This is a record of what was reviewed, not a promise
about what the owner will do with it.

**Complete.** The owner reports completion through `evaluate_task`'s own
`handoff_id` argument — not a separate tool — alongside `artifact_sha`,
`parent_commit`, `parent_gitlink` and `verification`. `artifact_sha` and
`parent_gitlink` must match: the commit that carries the artifact has to be
the one the parent checkout actually points at, or the handoff is refused as
`:gitlink_does_not_match_artifact`. A repeat completion with the same
evidence is idempotent; one with different evidence is refused as
`:conflicting_completion` rather than silently overwriting the first.

**Acknowledge.** Main is messaged when the owner completes it, and must call
`completion_handoff` with `action: "acknowledge"` and a note before whatever
the handoff's `next_action` names — commonly a promotion — proceeds.
Completing a handoff is not acknowledging it, and neither is a QA
certification: the tool's own reply says so every time, because receipt alone
was observed to read as "handled" when nobody had actually looked.

If delivery to main failed or was missed — the agent restarted, a message
timed out — `action: "redeliver"` re-sends a completed handoff without
re-running the work. Reconnecting does the same thing automatically for
anything still completed and undelivered.

## Do not trust a status tool over the rows

`devops_status` reports "N steps have nothing behind them" for any step whose
state is not literally `:done` — `project_checklist/2` reduces the whole
question to `if(step.state == :done, do: :present, else: :missing)` and never
reads `origin` or `resources`. On Broken Oaths it listed `server`, `domain`
and `dns` as missing while the rows held real registries, two databases, a
Hetzner network, verified A records, and a proven inbound email delivery.

Acting on that output nearly re-provisioned infrastructure that already
existed. Before authorising any provisioning, read `provisioning_steps` and
look at `resources` on each row. A step carrying resources is not absent
whatever its state says.

The same shape recurs elsewhere: `list_issues` is unfiltered while
`issues_resolved` counts only `scope: :app`, so an agent can see eleven
accepted issues, judge them all framework, and refuse work the gate says
exists. When a tool and a gate disagree, the gate is what the graph acts on.

## Spins are critical, and they cost money

An agent taking a turn every few seconds is burning tokens until someone stops
it. Treat it as a production incident:

1. **Stop the bleeding first** — `set_agent_continuous(continuous: false)`,
   then `turn_off_agent`, both from `run_script`. Diagnose afterwards.
2. **Measure before reporting.** Group by minute. `now()` is local and
   `inserted_at` is naive UTC; compare with `(now() at time zone 'UTC')` or a
   mild spin reads as a catastrophe.
3. **File it critical** with the per-minute numbers and the closed loop that
   produced it.

The shapes seen so far: an agent re-offered work it just declined; an agent
whose machine is unreachable, where the server records a prompt, fails to
dispatch, releases, and repeats with no agent involved at all; and an agent
whose turn was discarded holding a task nothing can wake.

## What the main agent should not do

- **Do not do a role's work** because it is quicker. The graph stops meaning
  anything.
- **Do not run a merge to see what it would do.** `--ff-only` is not a dry run.
  Use `git diff` or `git log --oneline HEAD..<other>`.
- **Do not file a framework bug without setting `scope`.** `create_issue`
  defaults to `:app`, which puts a bug in the tool onto the project's own
  `issues_resolved` gate, where its coding agent can never resolve it.
- **Do not restart the harness while analyzer runs are in flight.** It serves
  every working copy on the machine and the restart discards every agent's
  turn, on every project.
- **Do not answer a question addressed to the user.**

## When a story finishes

A story is done when its requirements are satisfied, not when the work feels
finished. Read them: `deploy` is commonly the last one and is commonly gated
on a devops decision that is deliberately off, in which case the story is as
complete as it is going to get and saying so is more useful than driving at
it.

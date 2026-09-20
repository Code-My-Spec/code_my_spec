# Internal agents: what's outstanding

Written 2026-09-17, after a night where QA of story 1005 produced no confirmed
criteria and the reasons turned out to be worth more than the story.

Two halves. **Filed** is already in the issue tracker and needs no re-capture —
listed only so nothing gets tracked twice. **Not filed** is everything proposed
in conversation that would otherwise evaporate.

---

## Filed — tool gaps, in priority order

The main agent is asked to run a fleet with tools that mostly answer about
itself. Top two are what block *leveraging* agents at all; the rest are
observability.

| id | sev | gap |
|---|---|---|
| `e15d1ff1` | high | **No way to hand a specific agent a specific piece of work.** `start_task`'s `agent_id` only stamps ownership; placement resolves from the caller, so the task lands on the caller's session. Found when an agent politely reported that the task I'd assigned it did not exist. |
| `d3660c2f` | high | **Cannot put an agent in the loop.** Can start/stop/restart but not set continuous — a started agent takes one turn and stops. |
| `23f5544e` | high | The stop menu **and the in-BEAM system prompt** name `list_tasks` to a surface that does not carry it. Two agents concluded their bindings were broken and stood down; one lost a day. |
| `0c912986` | medium | An agent stuck in `starting` is still treated as wakeable, so work routes to a process that never started. |
| `20e707e3` | medium | Could not read another agent's task queue. **Fixed and promoted** (v2.0.51). |
| `a4e338ae` | low | Agent tools crash on a malformed agent id instead of refusing. Every surface prints ids truncated to 8 chars, so passing one back is the obvious mistake. |

## Filed — criteria drift

Found by one coding agent in about an hour, unprompted, while trying to write
missing spec files:

- `d1aecac8` — story 863 carries **sixteen** criteria describing two mutually
  exclusive analytics architectures at once.
- `5a2e85d0` — criterion 2118 has no drivable surface without inventing test
  infrastructure whose only consumer would be the test.
- `51745e7d` — story 813's criterion 1715 assumes install instructions on `/app`,
  removed by `f84dffb9`.
- `d72e0c06` — criterion 3200 has no live requirement.
- `c31b6ade` — component with no spec.
- Also reported in conversation, not yet separately filed: criterion 1588 assumes
  stray-file detection `PersonasChecker`'s own moduledoc says it deliberately
  dropped; five criteria on 605/813 assume removed pages and a removed redirect.

Resolved or dismissed tonight, for the record: `ec56b436` (fixed), `9acca909`
(dismissed — right data, wrong mechanism), `0f24612e` (dismissed — `restart_agent`
is reachable from the main agent's surface, just not a qa agent's), `d500df3b`,
`a0780389`, `5151df37`.

---

## Not filed — proposed and outstanding

### 1. Stop persisting agent status; derive it from the GenServer

`agents.status` is written on clean start and clean stop, so it is a claim about
the past. `f8fbe49e` and `93bdde5a` have said `starting` for six hours with
nothing behind them, and `wakeable?` accepts `:starting`, so the graph routes
work to processes that never started.

John's position, and it is stronger than detecting the stale case: do not persist
it at all, represent the agent. If `wakeable?` asks the process, the whole class
disappears rather than being caught. Supersedes the fix implied by `0c912986`.

### 2. Derive the in-BEAM system prompt's tool list from `Engine.tools/1`

Appended as evidence to `23f5544e` but worth its own work. Two sources currently
describe an agent's surface and they disagree. `Engine.tools/1`'s own comments
record **six** prior instances of a tool being named somewhere an agent reads
while absent from that surface — `ask_user`, `send_message`,
`list_user_questions`, `check_answer`, `tap_out`, `promote` — each added after an
agent hit `Unknown tool`. `list_tasks` is the seventh. Derivation ends the class;
an assertion only holds the line.

### 3. Agent-behaviour story with evals  ← **built, 2026-09-17**

Story 1039 ("An agent does the right thing with the tools it has", spex directory
`1070`). Three Amigos sealed; all twelve criteria have spec files;
`bdd_specs_exist` satisfied. The measurements themselves are the remaining work
— see "What the evals cost and where they run" below.

What the first run found, before any criterion could be measured: **nothing in
this suite had ever let an agent take a real turn and then looked at what it
called**, and two things were quietly broken because of it.

- `InVmMcpTransport` implemented three tools and answered every direct one —
  `get_next_requirement`, `start_task`, `evaluate_task`, `tap_out` — with "This
  server has no tool called …", which is the sentence a genuinely missing tool
  answers with. It also dropped the `agent_id` the connection carries, so every
  task tool refused with "no session_id and no agent id on this call": the
  refusal written for a misconfigured connection, delivered on a correct one.
- An in-process agent's turn events went nowhere, because `on_event` defaults to
  a harness-registry lookup that finds nothing in a spex. So the transcript did
  not exist and the only thing to ask was the agent itself, which cannot
  distinguish a call from a claim about a call.

Both fixed in `59c4b3ae5`. Worth noticing rather than passing over: every
criterion in the fleet that "passes" today passed with an agent that could reach
three tools.

The agent's own conduct on both failures was correct — it reported the refusal
and declined to improvise around it, twice, unprompted. That is criteria 3543
and 3544's behaviour, observed before either was written.

#### Original plan, kept for the record

The agent is the user, the chat is the surface, tool calls are what you assert
on. Expressed as a story with criteria so it lands in the same requirement graph
and gates promotion like everything else, rather than being a side category
nobody runs.

Criteria drawn from behaviour actually observed tonight:

- starts work by asking what work there is (`get_next_requirement` → `start_task`)
- closes a task when the work is done (`evaluate_task`), and when the stop hook asks
- a QA agent reads the plan before writing a brief
- told to call a tool it does not carry, it reports rather than standing down
- with no work of its kind, taps out rather than inventing some
- refuses to write a spec for a criterion whose mechanism was removed
- whose context was trimmed, checks its own transcript before reporting a fault

The last three are behaviours to **protect** — currently a prompt change could
destroy them silently.

Two decisions already made:

- **Claude Code as the provider.** Already real (`engine: alloy, provider:
  claude-code`), so no scripted-provider infrastructure is needed. This also
  retires the blocker on criterion 2886, which wanted `HeldProvider` to emit tool
  calls.
- **Assert on properties, not transcripts** — "eventually calls `evaluate_task`",
  "never writes a spec after being shown the mechanism was removed". A flaky eval
  is a finding, not a nuisance: if the agent does the right thing only sometimes,
  the prompt is ambiguous, which is information we currently cannot get at all.

### 3a. What the evals cost, and where they run

One criterion is ten fresh agents each taking real turns against `claude -p`.
Roughly a minute a run, so a criterion is ten to fifteen minutes and the story
is two to three hours. That cannot live in the promote gate: the spex analyzer
runs under a deadline, and a measurement that has to finish inside somebody
else's deadline stops being one.

So they carry `@moduletag :eval`, `config :ex_unit, exclude: [:eval]` keeps them
out of every ordinary run, and `mix cms.eval` is the switch — `--runs N` to
lower the count while writing one, `--pattern criterion_NNNN` for one,
`CMS_EVAL_TRANSCRIPT=1` to print what the agent actually did. Run them when a
role brief, a system prompt or a tool list changes; that is when the answer can
have moved and the only time anything else would notice.

Two of the twelve (3537, 3538) are about the judging rather than the agent, are
deterministic, and run in the ordinary suite.

**Open, and it matters.** `bdd_specs_passing` on this story is a latch set by a
green spex run. Ten of the twelve files are excluded from that run, so the latch
would claim green over ten criteria that never executed — which is the exact
shape of the defect `SpecsPassingChecker`'s moduledoc was written about. The
requirement's own wording ("and evaluated to record it") points at the answer:
the eval run should be what records it. Not built.

### 4. Seed account, project and users as the eval substrate

**Superseded in part by how 3 landed.** The behavioural criteria build their own
seed inside the test database — `:synced_context_in_satisfied_project` for a
project with work, a bare project for the idle case — because a spex cannot
reach the dev database and a fixture-built project is the same on every run,
which is what "the same seeded project" has to mean for a rate to be
comparable.

What is still wanted is the browser-QA half: a seeded account and project in dev
that a QA agent can log into and watch. That was the original point and it is
unaffected.

Approved approach: a new account/project/users in the existing dev database,
rather than a per-worktree dev database. (`config/dev.exs` hardcodes
`code_my_spec_dev` while `config/test.exs` deliberately gives each checkout its
own via a recorded partition — changing dev was the alternative and was rejected
as too invasive.)

Not a prerequisite chore: it is what the evals run on. **QA of agent stories
should start fresh agents into this seed** — a long-lived agent's behaviour tells
you about its own history, not about the prompt and tools.

### 5. Static invariant checks (partly superseded by 3)

Two survive as cheap guards even with behavioural evals:

- every tool named in agent-facing prose exists on the surface of the role that
  reads it;
- the prompt's tool list equals `Engine.tools/1` (until item 2 makes it
  derivation).

Three were wrong and are dropped: "continuous means working" (the state is
`calling the LLM or not` × `blocked from stopping or not` × `superseded by
tap-out or question` — a matrix, not a bit), "`starting` beyond a bound is a
fault" (item 1 is the real fix), and "a copy whose graph reads empty is a fault"
(role filtering can legitimately empty a graph).

### 6. Smaller cleanups

- Six now-unreachable per-view copies of "That project is not yours, or does not
  exist." (`agent_conversation_live/{show,index}`, `working_copy_live/{index,show,form}`,
  `provisioning_live`). Dead since `PortableHost` started halting; worth deleting
  deliberately.
- `promote_sync` is now identical to `promote` and probably redundant.
- Criterion 2886 (story 956) still unwritten — needs an agent to really write a
  file, which item 3's provider decision now makes possible.

### 7. Environment repairs not done

- `devops-q` — `.code_my_spec` pinned at an Aug 21 commit whose `plan.md` carries
  a now-disallowed "auth strategy" section. Needs `git submodule update`.
- `1008-agent-lifecycle-qa` — submodule not initialised.
- `1004-qa-idle-agent-nudge` — same; its own coding agent has been asked.
- `963-main-agent-nontechnical` — repaired, but its 24MB gitignored
  `internal/agent_test_events.json` is parked at
  `.code_my_spec.stray-agent_test_events-20260916T210048` awaiting review.

Worktree isolation blocks this session from running git in any of them.

---

## The diagnosis these came from

1. **Production was the test fixture.** Agent-behaviour stories make claims about
   a fleet in a specific state; QA had no way to construct one, so it watched the
   live fleet and hoped. Six attempts on 1005, every one confounded.
2. **Criteria have drifted from the implementation, silently** — an unwritten
   spec reads as "not done yet" when it means "describes something deleted".
3. **Nothing supervises the supervisor.** Main agent `b49cb24a` sat blocked on
   unanswered questions from 09-15 02:00 for nearly two days; its only escalation
   is `ask_user_question`. While it was stopped, nothing was answering anyone
   else either — which is why the fleet looked unobservable.

Story 1017, "the main agent looks in on its agents on a cadence", is 7/7 while
(3) was true. Stories 1012 and 1014 are 7/7 while `20e707e3`, `d3660c2f` and
`e15d1ff1` are open against them. That coincidence is the single most useful
thing found tonight: **the epic is marked done while the capabilities are
missing**, which is what makes the fleet feel uncontrollable despite the stories
being complete.
